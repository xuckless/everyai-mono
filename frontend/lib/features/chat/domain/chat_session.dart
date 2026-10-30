import 'package:flutter/foundation.dart';

import '../../../core/net/api_error.dart';
import '../../models/domain/model_catalog.dart';
import 'message.dart';

/// Where a chat session is in its lifecycle. Transitions:
///
/// ```text
///  Loading ──► Idle ──send──► Awaiting ──first token──► Streaming ──done──► Idle
///                ▲              │   │                      │
///                │            cancel error               cancel / error
///                │              ▼   ▼                      ▼
///                └──retry/edit── Failed ◄──────────────────┘   (cancel ► Idle)
/// ```
sealed class TurnPhase {
  const TurnPhase();

  /// A turn is in flight: sending is blocked, the stop button shows.
  bool get busy => false;
}

final class Loading extends TurnPhase {
  const Loading();
}

final class Idle extends TurnPhase {
  const Idle();
}

/// Request sent, nothing received yet.
final class Awaiting extends TurnPhase {
  const Awaiting(this.assistantMessageId);
  final String assistantMessageId;
  @override
  bool get busy => true;
}

final class Streaming extends TurnPhase {
  const Streaming(this.assistantMessageId);
  final String assistantMessageId;
  @override
  bool get busy => true;
}

final class Failed extends TurnPhase {
  const Failed(this.error, {required this.prompt, required this.model});
  final ApiError error;

  /// What to resend on retry.
  final String prompt;
  final ModelSpec model;
}

@immutable
final class ChatSessionState {
  const ChatSessionState({
    required this.conversationId,
    required this.model,
    this.title,
    this.messages = const [],
    this.phase = const Loading(),
    this.streamingText = '',
    this.mode = ChatMode.chat,
    this.liveSources = const [],
    this.liveParts = const [],
    this.streamingReasoning = '',
    this.toolStatus = '',
    this.toolsEnabled = true,
  });

  final String conversationId;

  /// Null until the first message creates the conversation.
  final String? title;

  /// The conversation's default model (the @mention override is per message).
  final ModelSpec model;

  /// Finished messages plus the in-flight assistant placeholder. The list is
  /// replaced only when a message is added or finished, never per token, so
  /// list widgets don't rebuild while text streams in.
  final List<Message> messages;
  final TurnPhase phase;

  /// Text received so far for the in-flight assistant message. Bubbles select this.
  final String streamingText;

  final ChatMode mode;

  /// Sources for the in-flight answer, shown before its text arrives.
  final List<Source> liveSources;

  /// Finished segments of the in-flight answer (text before a tool call, tool
  /// calls, images), in order. [streamingText] is the segment still growing.
  final List<MessagePart> liveParts;

  /// The in-flight answer's thinking, so far.
  final String streamingReasoning;

  /// What a server tool is doing right now ("Reading example.com"), or empty.
  final String toolStatus;

  /// Whether the model may use tools (the composer's tools menu).
  final bool toolsEnabled;

  bool get isEmpty => messages.isEmpty;

  ChatSessionState copyWith({
    String? title,
    ModelSpec? model,
    List<Message>? messages,
    TurnPhase? phase,
    String? streamingText,
    ChatMode? mode,
    List<Source>? liveSources,
    List<MessagePart>? liveParts,
    String? streamingReasoning,
    String? toolStatus,
    bool? toolsEnabled,
  }) => ChatSessionState(
    conversationId: conversationId,
    title: title ?? this.title,
    model: model ?? this.model,
    messages: messages ?? this.messages,
    phase: phase ?? this.phase,
    streamingText: streamingText ?? this.streamingText,
    mode: mode ?? this.mode,
    liveSources: liveSources ?? this.liveSources,
    liveParts: liveParts ?? this.liveParts,
    streamingReasoning: streamingReasoning ?? this.streamingReasoning,
    toolStatus: toolStatus ?? this.toolStatus,
    toolsEnabled: toolsEnabled ?? this.toolsEnabled,
  );
}

/// Splits a leading or inline `@alias` from the prompt.
///
/// `"@claude explain this"` → (claude spec, `"explain this"`). Only the first
/// resolvable mention counts. Unknown `@words` (emails, handles) stay in the text.
({ModelSpec? model, String prompt}) parseMention(String input, ModelCatalog catalog) {
  final match = RegExp(r'(^|\s)@([\w.\-]+)')
      .allMatches(input)
      .map((m) {
        final spec = catalog.resolveMention(m.group(2)!);
        return spec == null ? null : (spec: spec, match: m);
      })
      .nonNulls
      .firstOrNull;
  if (match == null) return (model: null, prompt: input.trim());
  final m = match.match;
  final before = input.substring(0, m.start + m.group(1)!.length);
  final after = input.substring(m.end);
  return (model: match.spec, prompt: '$before$after'.replaceAll(RegExp(r'\s{2,}'), ' ').trim());
}

/// First line of the first prompt, trimmed for the history list.
String titleFromPrompt(String prompt) {
  final line = prompt.trim().split('\n').first;
  return line.length <= 60 ? line : '${line.substring(0, 57).trimRight()}…';
}
