import 'dart:convert';
import 'dart:ui' show Color;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/preferences.dart';
import '../code_providers.dart' show codeSessionsProvider;
import '../domain/code_session.dart';
import '../drivers/driver_registry.dart' show driverRegistryProvider;
import '../harness/harness.dart' show ReadsRecentEvents;
import '../domain/transcript.dart';
import '../ui/transcript/transcript_items.dart' show approvalTitle;

/// The Board's columns.
enum BoardColumn {
  needsYou('Needs you'),
  running('Running'),
  done('Done');

  const BoardColumn(this.label);
  final String label;

  static BoardColumn of(SessionStatus s) => switch (s) {
    SessionStatus.needsInput => needsYou,
    SessionStatus.running || SessionStatus.starting => running,
    SessionStatus.idle || SessionStatus.done || SessionStatus.failed => done,
  };
}

/// A session's status on the Board, counting the work it runs: a workflow (Security review, Ultra, …) runs while its
/// lead says nothing and sits idle, so the card is Running until the run ends; a workflow agent or fork waiting on the
/// user puts it under Needs you.
SessionStatus boardStatus(SessionStatus own, {required bool workRunning, required bool childWaits}) {
  if (own == SessionStatus.needsInput || childWaits) return SessionStatus.needsInput;
  if (workRunning && BoardColumn.of(own) == BoardColumn.done) return SessionStatus.running;
  return own;
}

/// A harness's two-letter mark and colour: the fallback for harnesses without a logo ([HarnessLogo]).
({String letters, Color color}) harnessMark(String harness) => switch (harness) {
  everyaiHarnessName => (letters: 'EA', color: const Color(0xFF7756E4)),
  'claude-code' => (letters: 'CC', color: const Color(0xFFC9694A)),
  'codex' => (letters: 'CX', color: const Color(0xFF10A37F)),
  'opencode' => (letters: 'OC', color: const Color(0xFF4B5563)),
  'gemini' => (letters: 'GM', color: const Color(0xFF3B6FE0)),
  _ => (
    letters: harness.replaceAll(RegExp('^acp:|^terminal:'), '').padRight(2).substring(0, 2).toUpperCase(),
    color: Color(0xFF000000 | (harness.hashCode * 2654435761 & 0x7F7F7F) + 0x303030),
  ),
};

/// What a session is doing, in one line, from its live transcript: the approval or question it waits on, else its
/// latest step or words. Empty when there is nothing to say.
String boardActivity(Transcript t) {
  if (t.pending.isNotEmpty) {
    final title = approvalTitle(t.pending.first);
    return t.pending.length == 1 ? title : '$title (+${t.pending.length - 1})';
  }
  for (final item in t.items.reversed) {
    switch (item) {
      case QuestionItem(:final questions, answers: null) when questions.isNotEmpty:
        return 'Asked: ${questions.first.question}';
      case StepItem(:final step):
        return stepTitle(step.call);
      case ExploreGroup(:final steps) when steps.isNotEmpty:
        return stepTitle(steps.last.call);
      case SubagentItem(:final step):
        return 'Subagent: ${step.call.summary.isEmpty ? step.call.toolName : step.call.summary}';
      case AgentText(:final text) when text.trim().isNotEmpty:
        return text.trim().split('\n').first;
      case UserTurn():
        if (t.streaming.trim().isNotEmpty) return t.streaming.trim().split('\n').last;
        return '';
      default:
        continue;
    }
  }
  return '';
}

/// Forks and subagents the user put on the Board (a top-level session is always there). Preferences
/// `code.board.detached`, a JSON list of session ids.
final boardDetachedProvider = NotifierProvider<BoardDetached, Set<String>>(BoardDetached.new);

final class BoardDetached extends Notifier<Set<String>> {
  static const key = 'code.board.detached';

  @override
  Set<String> build() {
    final raw = ref.read(preferencesProvider)[key];
    if (raw == null) return const {};
    try {
      return {...(jsonDecode(raw) as List).whereType<String>()};
    } on Object {
      return const {};
    }
  }

  void toggle(String id) {
    state = state.contains(id) ? ({...state}..remove(id)) : {...state, id};
    ref.read(preferencesProvider)[key] = jsonEncode([...state]);
  }
}

/// Done cards the user cleared off the Board (Preferences `code.board.dismissed`). A session that runs again comes
/// back: the Board drops its id once it leaves Done.
final boardDismissedProvider = NotifierProvider<BoardDismissed, Set<String>>(BoardDismissed.new);

final class BoardDismissed extends Notifier<Set<String>> {
  static const key = 'code.board.dismissed';

  @override
  Set<String> build() {
    final raw = ref.read(preferencesProvider)[key];
    if (raw == null) return const {};
    try {
      return {...(jsonDecode(raw) as List).whereType<String>()};
    } on Object {
      return const {};
    }
  }

  void _set(Set<String> ids) {
    state = ids;
    ref.read(preferencesProvider)[key] = jsonEncode([...ids]);
  }

  void dismiss(Iterable<String> ids) => _set({...state, ...ids});

  void restore(Iterable<String> ids) {
    if (ids.any(state.contains)) _set({...state}..removeAll(ids));
  }
}

/// The Board's column widths as shares of its width (three, summing to 1); Preferences `code.board.columns`.
final boardColumnsProvider = NotifierProvider<BoardColumns, List<double>>(BoardColumns.new);

final class BoardColumns extends Notifier<List<double>> {
  static const key = 'code.board.columns';
  static const even = [1 / 3, 1 / 3, 1 / 3];

  @override
  List<double> build() {
    final raw = ref.read(preferencesProvider)[key];
    try {
      final list = [for (final v in jsonDecode(raw ?? '') as List) (v as num).toDouble()];
      if (list.length == 3 && list.every((v) => v > 0)) return list;
    } on Object {
      // Missing or malformed: even columns.
    }
    return even;
  }

  /// New shares; [persist] is false while dragging.
  void set(List<double> shares, {bool persist = true}) {
    final total = shares.fold<double>(0, (a, b) => a + b);
    state = [for (final v in shares) v / total];
    if (persist) ref.read(preferencesProvider)[key] = jsonEncode(state);
  }

  void reset() => set(even);
}

/// The sessions the Board shows: every top-level session plus the detached forks, newest first. Sessions of a
/// removed harness (they can't be reopened) stay off.
List<CodeSessionInfo> boardSessions(List<CodeSessionInfo> all, Set<String> detached) => [
  for (final s in all)
    if ((s.parentId == null || detached.contains(s.id)) && !s.removedHarness) s,
]..sort((a, b) => b.createdAt.compareTo(a.createdAt));

/// What a closed session last did, read from its harness's files (null when the harness keeps none). Keyed by the
/// session and its status, so a status change reads it again.
final boardRecentTranscriptProvider = FutureProvider.autoDispose.family<Transcript?, (String, SessionStatus)>((
  ref,
  key,
) async {
  final info = ref.read(codeSessionsProvider).where((s) => s.id == key.$1).firstOrNull;
  if (info == null || info.removedHarness) return null;
  final driver = ref.read(driverRegistryProvider).resolve(info.harness);
  if (driver is! ReadsRecentEvents) return null;
  try {
    final events = await (driver as ReadsRecentEvents).recentEvents(info.conversationId);
    final builder = TranscriptBuilder();
    events.forEach(builder.add);
    return builder.snapshot;
  } on Object {
    return null;
  }
});
