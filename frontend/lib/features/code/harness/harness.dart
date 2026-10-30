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
    this.runInitial = true,
    this.maxInputTokens,
    this.maxOutputTokens = 64000,
    this.vision = false,
    this.initialImages = const [],
    this.persona,
    this.promptSuffix,
    this.effort,
    this.holdClientTools = false,
    this.subagent = false,
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

  /// Whether [initialMessage] starts the agent; off, it waits for the next
  /// message (a compacted session's summary, say).
  final bool runInitial;

  /// The model's context window, so the agent condenses its history in time.
  final int? maxInputTokens;

  /// Room for thinking plus a whole-file edit in one reply.
  final int maxOutputTokens;

  /// The model reads images: OpenHands passes them on instead of dropping them.
  final bool vision;

  /// `data:` URLs sent with [initialMessage].
  final List<String> initialImages;

  /// Replaces the agent-server's persona and workflow sections (see
  /// `agentPersona`); null keeps its defaults.
  final String? persona;

  /// Appended to the system prompt; defaults to `workingRules`.
  final String? promptSuffix;

  /// Reasoning effort: low, medium, high, xhigh or max (null: the server's).
  final String? effort;

  /// Question cards and plans are held for confirmation and answered inside
  /// the call (a rejection whose reason carries the reply, then a run), so
  /// the agent keeps its turn. Off: the agent ends its turn and the reply is
  /// a new user message.
  final bool holdClientTools;

  /// A child conversation started by another session's `run_subagent` call: no
  /// client tools (so it can't ask the user or start subagents of its own),
  /// and `subagentRules` after the prompt suffix.
  final bool subagent;
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

  /// Changes the confirmation policy; [holdClientTools] as in [SessionSpec].
  Future<void> setMode(AgentMode mode, {bool holdClientTools = false});
  Future<void> close();
}

/// Starts and reopens sessions on some agent server.
abstract interface class Harness {
  Future<HarnessSession> start(SessionSpec spec);
  Future<HarnessSession> attach(String conversationId);

  /// The execution status of each of [conversationIds] the server knows,
  /// without opening their event streams (for session lists).
  Future<Map<String, ExecutionStatus>> statuses(List<String> conversationIds);
}
