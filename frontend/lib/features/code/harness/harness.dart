import 'package:flutter/foundation.dart';

import '../domain/agent_mode.dart';
import 'events.dart';

/// What a new coding session needs.
@immutable
final class SessionSpec {
  const SessionSpec({
    required this.workingDir,
    required this.model,
    required this.mode,
    required this.llmBaseUrl,
    required this.llmApiKey,
    required this.sessionTag,
    this.initialMessage,
    this.maxInputTokens,
    this.vision = false,
    this.initialImages = const [],
  });

  /// The session's worktree.
  final String workingDir;

  /// OpenRouter model id (`anthropic/claude-sonnet-5.5`).
  final String model;
  final AgentMode mode;

  /// The EveryAI gateway (`…/v1`) and the user's gateway key.
  final String llmBaseUrl;
  final String llmApiKey;

  /// Sent as `X-EveryAI-Session` so usage is attributed to the session.
  final String sessionTag;
  final String? initialMessage;

  /// The model's context window, so the agent condenses its history in time.
  final int? maxInputTokens;

  /// The model reads images: OpenHands passes them on instead of dropping them.
  final bool vision;

  /// `data:` URLs sent with [initialMessage].
  final List<String> initialImages;
}

/// A running agent conversation. Events arrive on [events] (history first,
/// then live); the methods steer it.
abstract interface class HarnessSession {
  String get id;
  Stream<HarnessEvent> get events;

  /// Sends a user message, with [images] as `data:` URLs. [run] starts the
  /// agent if it is idle.
  Future<void> send(String text, {bool run = true, List<String> images = const []});

  /// Stops the current step (the agent can continue with a new message).
  Future<void> interrupt();
  Future<void> pause();
  Future<void> resume();

  /// Answers the pending action that needs approval.
  Future<void> respond({required bool accept, String? reason});

  Future<void> setMode(AgentMode mode);
  Future<void> close();
}

/// Starts and reopens sessions on some agent server.
abstract interface class Harness {
  Future<HarnessSession> start(SessionSpec spec);
  Future<HarnessSession> attach(String conversationId);
}
