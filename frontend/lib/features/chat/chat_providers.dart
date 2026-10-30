import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/api_error.dart';
import '../../core/providers.dart';
import '../models/domain/model_catalog.dart';
import '../models/models_providers.dart';
import 'data/chat_repository.dart';
import 'data/chat_transport.dart';
import 'domain/chat_session.dart';
import 'domain/message.dart';

final chatRepositoryProvider = Provider<ChatRepository>((ref) => ChatRepository(ref.watch(databaseProvider)));

final chatTransportProvider = Provider<ChatTransport>((ref) {
  final api = ref.watch(apiClientProvider);
  return TransportRouter(
    post: PostTransport(api),
    sse: SseTransport(api),
    sseEnabled: ref.watch(appConfigProvider).sseEnabled,
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

  /// Changes the conversation's default model (the toolbar picker).
  void selectModel(ModelSpec model) {
    if (state.phase.busy) return;
    state = state.copyWith(model: model);
  }

  /// Idle/Failed → Awaiting. Ignored while a turn is in flight.
  Future<void> send(String input) async {
    if (state.phase.busy || state.phase is Loading) return;
    final (:model, :prompt) = parseMention(input, _catalog);
    if (prompt.isEmpty) return;
    await _startTurn(prompt: prompt, model: model ?? state.model, userText: input.trim());
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

  Future<void> _startTurn({required String prompt, required ModelSpec model, required String? userText}) async {
    if (!model.available) {
      state = state.copyWith(
        phase: Failed(HttpStatusError(501, '${model.name} is not available yet.'), prompt: prompt, model: model),
      );
      return;
    }

    if (state.title == null) {
      final c = await _repo.createConversationWithId(
        id: conversationId,
        title: titleFromPrompt(prompt),
        model: state.model.id,
      );
      if (!ref.mounted) return;
      state = state.copyWith(title: c.title);
    }

    final history = state.messages;
    final messages = [...history];
    if (userText != null) {
      final user = Message(
        id: _repo.newId(),
        conversationId: conversationId,
        role: Role.user,
        parts: [TextPart(userText)],
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
    final cancel = _cancel = Completer<void>();
    state = state.copyWith(messages: List.unmodifiable(messages), phase: Awaiting(assistant.id), streamingText: '');

    final parts = <MessagePart>[];
    final events = ref
        .read(chatTransportProvider)
        .send(
          ChatRequest(model: model, prompt: prompt, history: history),
          cancel: cancel.future,
        );

    _turn = events.listen(
      (event) {
        switch (event) {
          case TextDelta(:final text):
            _buffer.write(text);
            state = state.copyWith(phase: Streaming(assistant.id), streamingText: _buffer.toString());
          case ImageOutput(:final bytes, :final mimeType):
            parts.add(ImagePart(bytes: bytes, mimeType: mimeType));
          case TurnDone():
            break;
        }
      },
      onError: (Object error) {
        final apiError = error is ApiError ? error : ProtocolError('$error');
        if (apiError is CancelledError || cancel.isCompleted) {
          _finish(assistant, parts, MessageStatus.cancelled, phase: const Idle());
        } else {
          _finish(
            assistant,
            parts,
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
          parts,
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
    final text = _buffer.toString();
    final finished = assistant.copyWith(
      parts: [if (text.isNotEmpty) TextPart(text), ...parts],
      status: status,
      error: error,
    );
    state = state.copyWith(
      messages: List.unmodifiable([for (final m in state.messages) m.id == assistant.id ? finished : m]),
      phase: phase,
      streamingText: '',
    );
    _turn = null;
    _cancel = null;
    if (status != MessageStatus.failed || finished.parts.isNotEmpty) {
      unawaited(_repo.saveMessage(finished));
    }
  }
}
