import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/api_error.dart';
import '../../core/providers.dart';
import '../attachments/attachment.dart';
import '../models/domain/model_catalog.dart';
import '../models/models_providers.dart';
import '../usage/usage_totals.dart';
import 'data/chat_repository.dart';
import 'data/chat_transport.dart';
import 'domain/chat_session.dart';
import 'domain/message.dart';

final chatRepositoryProvider = Provider<ChatRepository>((ref) => ChatRepository(ref.watch(databaseProvider)));

final chatTransportProvider = Provider<ChatTransport>((ref) {
  final api = ref.watch(apiClientProvider);
  // With dev auth the backend serves anonymous requests as its dev user.
  final authenticated = !ref.watch(appConfigProvider).devSkipAuth;
  return TransportRouter(
    stream: SseTransport(api, authenticated: authenticated),
    image: ImageTransport(api, authenticated: authenticated),
  );
});

final conversationsProvider = StreamProvider<List<Conversation>>(
  (ref) => ref.watch(chatRepositoryProvider).watchConversations(),
);

/// One controller per conversation id. New chats get a fresh id up front, and the
/// row is created on first send, so the key never changes mid-turn.
final chatSessionProvider = NotifierProvider.autoDispose.family<ChatController, ChatSessionState, String>(
  ChatController.new,
);

final class ChatController extends Notifier<ChatSessionState> {
  ChatController(this.conversationId);

  final String conversationId;
  Completer<void>? _cancel;
  StreamSubscription<ChatEvent>? _turn;
  final _buffer = StringBuffer();
  final _reasoning = StringBuffer();

  ChatRepository get _repo => ref.read(chatRepositoryProvider);
  ModelCatalog get _catalog => ref.read(modelCatalogProvider);

  @override
  ChatSessionState build() {
    ref.onDispose(() {
      _cancel?.complete();
      _turn?.cancel();
    });
    unawaited(_load());
    return ChatSessionState(conversationId: conversationId, model: ref.read(defaultModelProvider));
  }

  Future<void> _load() async {
    final conversation = await _repo.conversation(conversationId);
    final messages = conversation == null ? const <Message>[] : await _repo.messages(conversationId);
    if (!ref.mounted) return;
    state = state.copyWith(
      title: conversation?.title,
      model: conversation == null ? null : _catalog[conversation.model] ?? state.model,
      messages: List.unmodifiable(messages),
      phase: const Idle(),
    );
  }

  /// Changes the conversation's model (the composer's model picker).
  void selectModel(ModelSpec model) {
    if (state.phase.busy) return;
    state = state.copyWith(model: model);
  }

  /// Idle/Failed → Awaiting. Ignored while a turn is in flight.
  Future<void> send(String input, {List<Attachment> attachments = const []}) async {
    if (state.phase.busy || state.phase is Loading) return;
    final (:model, :prompt) = parseMention(input, _catalog);
    if (prompt.isEmpty && attachments.isEmpty) return;
    await _startTurn(
      prompt: prompt,
      model: model ?? state.model,
      userText: input.trim(),
      attachments: [for (final a in attachments) AttachmentPart.of(a)],
    );
  }

  void setMode(ChatMode mode) => state = state.copyWith(mode: mode);

  void setToolsEnabled(bool enabled) => state = state.copyWith(toolsEnabled: enabled);

  /// Idle/Failed → Awaiting: drops the last answer and asks again, optionally
  /// with a different model ("Retry with…").
  Future<void> regenerate({ModelSpec? model}) async {
    if (state.phase.busy || state.phase is Loading) return;
    final lastUser = state.messages.lastIndexWhere((m) => m.isUser);
    if (lastUser == -1) return;
    final dropped = state.messages.sublist(lastUser + 1);
    final previousModel = dropped.map((m) => m.model).nonNulls.map((id) => _catalog[id]).nonNulls.firstOrNull;
    state = state.copyWith(messages: List.unmodifiable(state.messages.take(lastUser + 1)));
    await _repo.deleteMessages(dropped.map((m) => m.id));
    final (model: mentioned, :prompt) = parseMention(state.messages[lastUser].plainText, _catalog);
    await _startTurn(prompt: prompt, model: model ?? previousModel ?? mentioned ?? state.model, userText: null);
  }

  /// Replaces a user message and everything after it, then answers the new text.
  Future<void> editAndResend(String userMessageId, String text) async {
    if (state.phase.busy || state.phase is Loading) return;
    final index = state.messages.indexWhere((m) => m.id == userMessageId);
    if (index == -1) return;
    final dropped = state.messages.sublist(index);
    // The edited message keeps its attachments.
    final attachments = dropped.first.attachments;
    state = state.copyWith(messages: List.unmodifiable(state.messages.take(index)), phase: const Idle());
    await _repo.deleteMessages(dropped.map((m) => m.id));
    final (:model, :prompt) = parseMention(text, _catalog);
    await _startTurn(prompt: prompt, model: model ?? state.model, userText: text.trim(), attachments: attachments);
  }

  /// Failed → Awaiting with the same prompt and model.
  Future<void> retry() async {
    if (state.phase case Failed(:final prompt, :final model)) {
      // Drop the failed assistant message. The user message stays.
      final messages = state.messages.where((m) => !(m.role == Role.assistant && m.status == MessageStatus.failed));
      state = state.copyWith(messages: List.unmodifiable(messages));
      await _startTurn(prompt: prompt, model: model, userText: null);
    }
  }

  /// Awaiting/Streaming → Idle, keeping whatever text arrived.
  void cancel() {
    if (!state.phase.busy) return;
    _cancel?.complete();
  }

  /// [userText] null: answer the last user message again (retry, regenerate).
  Future<void> _startTurn({
    required String prompt,
    required ModelSpec model,
    required String? userText,
    List<AttachmentPart> attachments = const [],
  }) async {
    if (state.title == null) {
      final c = await _repo.createConversationWithId(
        id: conversationId,
        title: titleFromPrompt(prompt.isNotEmpty ? prompt : attachments.firstOrNull?.name ?? 'Attachment'),
        model: state.model.id,
      );
      if (!ref.mounted) return;
      state = state.copyWith(title: c.title);
    }

    var history = state.messages;
    if (userText == null) {
      // The last user message is the prompt; it isn't history too.
      final last = history.lastIndexWhere((m) => m.isUser);
      if (last != -1) {
        attachments = history[last].attachments;
        history = history.sublist(0, last);
      }
    }
    final messages = [...state.messages];
    if (userText != null) {
      final user = Message(
        id: _repo.newId(),
        conversationId: conversationId,
        role: Role.user,
        parts: [...attachments, if (userText.isNotEmpty) TextPart(userText)],
        createdAt: DateTime.now(),
      );
      messages.add(user);
      unawaited(_repo.saveMessage(user));
    }
    final assistant = Message(
      id: _repo.newId(),
      conversationId: conversationId,
      role: Role.assistant,
      parts: const [],
      createdAt: DateTime.now(),
      model: model.id,
      status: MessageStatus.streaming,
    );
    messages.add(assistant);

    _buffer.clear();
    _reasoning.clear();
    final cancel = _cancel = Completer<void>();
    state = state.copyWith(
      messages: List.unmodifiable(messages),
      phase: Awaiting(assistant.id),
      streamingText: '',
      liveSources: const [],
      liveParts: const [],
      streamingReasoning: '',
      toolStatus: '',
    );

    // Segments in arrival order: text before a tool call, the call, more text…
    final parts = <MessagePart>[];
    var sources = const <Source>[];
    var followUps = const <String>[];
    var usage = UsageTotals.zero;
    void flushText() {
      if (_buffer.isEmpty) return;
      parts.add(TextPart(_buffer.toString()));
      _buffer.clear();
    }

    List<MessagePart> collect() {
      flushText();
      return [
        if (_reasoning.isNotEmpty) ReasoningPart(_reasoning.toString()),
        if (sources.isNotEmpty) SourcesPart(sources),
        ...parts,
        if (followUps.isNotEmpty) FollowUpsPart(followUps),
        if (!usage.isEmpty) UsagePart(usage),
      ];
    }

    final events = ref
        .read(chatTransportProvider)
        .send(
          ChatRequest(
            model: model,
            prompt: prompt,
            history: history,
            mode: state.mode,
            conversationId: conversationId,
            toolsEnabled: state.toolsEnabled,
            attachments: attachments,
          ),
          cancel: cancel.future,
        );

    _turn = events.listen(
      (event) {
        switch (event) {
          case TextDelta(:final text):
            _buffer.write(text);
            state = state.copyWith(phase: Streaming(assistant.id), streamingText: _buffer.toString(), toolStatus: '');
          case ReasoningDelta(:final text):
            _reasoning.write(text);
            state = state.copyWith(streamingReasoning: _reasoning.toString());
          case ImageOutput(:final bytes, :final mimeType):
            flushText();
            parts.add(ImagePart(bytes: bytes, mimeType: mimeType));
            state = state.copyWith(
              phase: Streaming(assistant.id),
              liveParts: List.unmodifiable(parts),
              streamingText: '',
            );
          case UiToolCall(:final id, :final name, :final argumentsJson):
            flushText();
            parts.add(ToolCallPart(toolName: name, argumentsJson: argumentsJson, callId: id));
            state = state.copyWith(
              phase: Streaming(assistant.id),
              liveParts: List.unmodifiable(parts),
              streamingText: '',
            );
          case ToolProgress(:final name, :final status, :final detail):
            state = state.copyWith(toolStatus: status == ToolRunStatus.running ? toolStatusLabel(name, detail) : '');
          case SourcesFound(sources: final found):
            sources = List.unmodifiable([...sources, ...found]);
            state = state.copyWith(liveSources: sources);
          case final UsageReport r:
            usage = usage.addCall(
              prompt: r.promptTokens,
              completion: r.completionTokens,
              cached: r.cachedTokens,
              cacheWrite: r.cacheWriteTokens,
              charged: r.chargedMicros,
              context: !r.followUps,
            );
            state = state.copyWith(liveUsage: usage);
          case FollowUpsSuggested(:final questions):
            followUps = questions;
          case TurnDone():
            break;
        }
      },
      onError: (Object error) {
        final apiError = error is ApiError ? error : ProtocolError('$error');
        if (apiError is CancelledError || cancel.isCompleted) {
          _finish(assistant, collect(), MessageStatus.cancelled, phase: const Idle());
        } else {
          _finish(
            assistant,
            collect(),
            MessageStatus.failed,
            error: apiError.message,
            phase: Failed(apiError, prompt: prompt, model: model),
          );
        }
      },
      onDone: () {
        if (state.phase is Failed || !state.phase.busy) return;
        _finish(
          assistant,
          collect(),
          cancel.isCompleted ? MessageStatus.cancelled : MessageStatus.complete,
          phase: const Idle(),
        );
      },
      cancelOnError: true,
    );
  }

  void _finish(
    Message assistant,
    List<MessagePart> parts,
    MessageStatus status, {
    String? error,
    required TurnPhase phase,
  }) {
    if (!ref.mounted) return;
    final finished = assistant.copyWith(parts: parts, status: status, error: error);
    state = state.copyWith(
      messages: List.unmodifiable([for (final m in state.messages) m.id == assistant.id ? finished : m]),
      phase: phase,
      streamingText: '',
      liveSources: const [],
      liveParts: const [],
      streamingReasoning: '',
      toolStatus: '',
      liveUsage: UsageTotals.zero,
    );
    _turn = null;
    _cancel = null;
    if (status != MessageStatus.failed || finished.parts.isNotEmpty) {
      unawaited(_repo.saveMessage(finished));
    }
  }
}

/// The status line shown while a server tool runs.
String toolStatusLabel(String tool, String? detail) => switch (tool) {
  'web_fetch' => 'Reading ${Uri.tryParse(detail ?? '')?.host ?? 'the page'}…',
  'generate_image' => 'Creating an image…',
  _ => 'Working…',
};
