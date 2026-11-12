import 'dart:convert';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/preferences.dart';
import '../code_providers.dart' show codeSessionProvider, codeSessionsProvider;
import '../domain/permissions.dart' show ApprovalScope;
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
    SessionStatus.running || SessionStatus.starting || SessionStatus.paused => running,
    SessionStatus.idle || SessionStatus.done || SessionStatus.failed => done,
  };
}

/// A session's status on the Board, counting the work it runs: a workflow (Security review, Ultra, …) runs while its
/// lead says nothing and sits idle, so the card is Running until the run ends; a workflow agent or fork waiting on the
/// user puts it under Needs you.
SessionStatus boardStatus(SessionStatus own, {required bool workRunning, required bool childWaits}) {
  if (own == SessionStatus.needsInput || childWaits) return SessionStatus.needsInput;
  // A failed session stays failed (broken, or its budget spent) even while a workflow still runs: Running would hide it.
  if (workRunning && (own == SessionStatus.idle || own == SessionStatus.done)) return SessionStatus.running;
  return own;
}

/// Sessions by the session that started them (forks and subagents under their lead).
Map<String, List<CodeSessionInfo>> childrenByParent(Iterable<CodeSessionInfo> sessions) {
  final out = <String, List<CodeSessionInfo>>{};
  for (final c in sessions) {
    if (c.parentId case final p?) (out[p] ??= []).add(c);
  }
  return out;
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

/// What the Board knows about a session's last finish, and whether the user has looked since (one state per session,
/// moved only by [seenTransition]):
///
/// ```text
///   NotTracked ──Finished──▶ FinishedUnseen ──Looked──▶ FinishedSeen
///        │  ▲                     │   ▲                      │
///        │  └──────Ran────────────┴───┼──────Ran─────────────┘
///        └──Looked (it is finished)───┴─▶ FinishedSeen   RunningAgain ──Finished──▶ FinishedUnseen
/// ```
///
/// A session in Done is tracked from when the Board first saw it there ([FinishedUnseen.since]); once it runs again
/// the marks are dropped, so its next finish is news. Auto-clear ([staleDone]) reads `since`; a cleared session is
/// dismissed (`boardDismissedProvider`) and its marks go.
sealed class SeenState {
  const SeenState();
}

/// Nothing recorded (never finished here, or cleared).
final class NotTracked extends SeenState {
  const NotTracked();
  @override
  bool operator ==(Object other) => other is NotTracked;
  @override
  int get hashCode => 0;
}

/// Finished at [since]; the user hasn't looked since.
final class FinishedUnseen extends SeenState {
  const FinishedUnseen(this.since);
  final DateTime since;
  @override
  bool operator ==(Object other) => other is FinishedUnseen && other.since == since;
  @override
  int get hashCode => Object.hash(1, since);
}

/// Finished at [since]; the user looked at [seenAt] (at or after the finish).
final class FinishedSeen extends SeenState {
  const FinishedSeen(this.since, this.seenAt);
  final DateTime since;
  final DateTime seenAt;
  @override
  bool operator ==(Object other) => other is FinishedSeen && other.since == since && other.seenAt == seenAt;
  @override
  int get hashCode => Object.hash(2, since, seenAt);
}

/// It was finished and runs again: the marks are dropped (stored as nothing, so a later load reads [NotTracked]).
final class RunningAgain extends SeenState {
  const RunningAgain();
  @override
  bool operator ==(Object other) => other is RunningAgain;
  @override
  int get hashCode => 3;
}

sealed class SeenEvent {
  const SeenEvent();
}

/// The Board sees the session in Done; [at] is when it counts from (used when it wasn't tracked yet).
final class Finished extends SeenEvent {
  const Finished(this.at);
  final DateTime at;
}

/// The user looks at the finished session (opens it).
final class Looked extends SeenEvent {
  const Looked(this.at);
  final DateTime at;
}

/// The session runs (or waits, or is paused).
final class Ran extends SeenEvent {
  const Ran();
}

/// The one transition function of a session's seen state.
SeenState seenTransition(SeenState state, SeenEvent event) => switch ((state, event)) {
  (NotTracked() || RunningAgain(), Finished(:final at)) => FinishedUnseen(at),
  // Looking at a finished session records the finish (and that it was seen) if the Board hadn't yet.
  (NotTracked() || RunningAgain(), Looked(:final at)) => FinishedSeen(at, at),
  (NotTracked(), Ran()) => const NotTracked(),
  (RunningAgain(), Ran()) => state,
  (FinishedUnseen() || FinishedSeen(), Ran()) => const RunningAgain(),
  (FinishedUnseen(), Finished()) => state,
  (FinishedSeen(), Finished()) => state,
  (FinishedUnseen(:final since), Looked(:final at)) => FinishedSeen(since, at),
  (FinishedSeen(), Looked()) => state,
};

/// Whether the Board has recorded finishes before: sessions already Done on the first run count from when they were
/// created; after that, a newly seen finish counts from now.
enum MarksEra { firstRun, tracking }

/// Every session's [SeenState] (those not listed are [NotTracked]).
class BoardMarkSet {
  const BoardMarkSet(this.era, this.marks);

  final MarksEra era;
  final Map<String, SeenState> marks;

  SeenState of(String id) => marks[id] ?? const NotTracked();

  /// When [id], seen in Done now, counts from.
  DateTime finishedAt(DateTime createdAt, DateTime now) => era == MarksEra.firstRun ? createdAt : now;
}

/// The Board's marks, kept in Preferences `code.board.done_since` (id → finish, epoch ms) and `code.board.seen` (id →
/// when the user looked); the only writer, for the Board's refresh, the session view and the card.
final boardMarksProvider = NotifierProvider<BoardMarks, BoardMarkSet>(BoardMarks.new);

final class BoardMarks extends Notifier<BoardMarkSet> {
  static const doneSinceKey = 'code.board.done_since';
  static const seenKey = 'code.board.seen';

  @override
  BoardMarkSet build() {
    final prefs = ref.read(preferencesProvider);
    Map<String, int>? ints(String? raw) {
      if (raw == null) return null;
      try {
        return {for (final e in (jsonDecode(raw) as Map<String, Object?>).entries) e.key: (e.value as num).toInt()};
      } on Object {
        return const {};
      }
    }

    final since = ints(prefs[doneSinceKey]);
    final seen = ints(prefs[seenKey]) ?? const <String, int>{};
    DateTime at(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);
    final era = since == null ? MarksEra.firstRun : MarksEra.tracking;
    return BoardMarkSet(era, {
      for (final MapEntry(key: id, value: ms) in (since ?? const <String, int>{}).entries)
        id: switch (seen[id]) {
          final seenMs? when seenMs >= ms => FinishedSeen(at(ms), at(seenMs)),
          _ => FinishedUnseen(at(ms)),
        },
      // Before the first record, a look is all there is (it counts as the finish too).
      if (era == MarksEra.firstRun)
        for (final MapEntry(key: id, value: ms) in seen.entries) id: FinishedSeen(at(ms), at(ms)),
    });
  }

  /// One session's event ([markBoardSeen], the card's open). Writes only when the state changes.
  void apply(String id, SeenEvent event) => _set(state.era, _step({...state.marks}, id, event));

  /// The Board's refresh: the Done sessions' projected [finished] states (not cleared), the ids that [ran] again
  /// and the ids [gone] (cleared, dismissed or deleted). The first refresh moves the marks to tracking.
  void sync({
    required Map<String, SeenState> finished,
    Iterable<String> ran = const [],
    Iterable<String> gone = const [],
  }) {
    final next = {...state.marks};
    for (final id in gone) {
      next.remove(id);
    }
    next.addAll(finished);
    for (final id in ran) {
      _step(next, id, const Ran());
    }
    _set(MarksEra.tracking, next);
  }

  Map<String, SeenState> _step(Map<String, SeenState> marks, String id, SeenEvent event) {
    final to = seenTransition(marks[id] ?? const NotTracked(), event);
    if (to is NotTracked || to is RunningAgain) {
      marks.remove(id);
    } else {
      marks[id] = to;
    }
    return marks;
  }

  void _set(MarksEra era, Map<String, SeenState> marks) {
    if (era == state.era && mapEquals(marks, state.marks)) return;
    state = BoardMarkSet(era, marks);
    final prefs = ref.read(preferencesProvider);
    if (era == MarksEra.tracking) {
      prefs[doneSinceKey] = jsonEncode({
        for (final e in marks.entries)
          if (e.value case FinishedUnseen(:final since) || FinishedSeen(:final since))
            e.key: since.millisecondsSinceEpoch,
      });
    }
    prefs[seenKey] = jsonEncode({
      for (final e in marks.entries)
        if (e.value case FinishedSeen(:final seenAt)) e.key: seenAt.millisecondsSinceEpoch,
    });
  }

  /// Puts back the marks of [marks] (Undo of a clear): they return as they were, not as fresh finishes.
  void restore(Map<String, SeenState> marks) {
    if (marks.isEmpty) return;
    _set(state.era, {...state.marks, ...marks});
  }
}

/// How long a finished session stays in Done, and how many stay at most; older ones clear by themselves.
const boardDoneFor = Duration(days: 2);
const boardDoneKeep = 8;

/// The Done sessions to clear by themselves: those done longer than [maxAge] ago, and past the newest [keep].
Set<String> staleDone(
  Map<String, DateTime> doneSince, {
  required DateTime now,
  Duration maxAge = boardDoneFor,
  int keep = boardDoneKeep,
}) {
  final newest = doneSince.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  return {
    for (final (i, e) in newest.indexed)
      if (i >= keep || now.difference(e.value) > maxAge) e.key,
  };
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

/// The Board's side inspector width in points; Preferences `code.board.inspector`.
final boardInspectorWidthProvider = NotifierProvider<BoardInspectorWidth, double>(BoardInspectorWidth.new);

final class BoardInspectorWidth extends Notifier<double> {
  static const key = 'code.board.inspector';
  static const initial = 440.0;
  static const min = 340.0;
  static const max = 760.0;

  @override
  double build() => (double.tryParse(ref.read(preferencesProvider)[key] ?? '') ?? initial).clamp(min, max);

  void set(double width) {
    state = width.clamp(min, max);
    ref.read(preferencesProvider)[key] = state.toStringAsFixed(0);
  }

  void reset() => set(initial);
}

/// Approves or denies calls [callIds] of session [sessionId] from the Board, on the session's own controller.
/// How the Board carries a session on after its usage limit reset (a card's Resume): why nothing started, or null.
typedef BoardResume = Future<String?> Function(String sessionId);

/// Every harness's lead gets a carry-on turn ([CodeSessionController.resumeAfterLimit]); tests listen in here.
final boardResumeProvider = Provider<BoardResume>(
  (ref) =>
      (sessionId) => ref.read(codeSessionProvider(sessionId).notifier).resumeAfterLimit(),
);

typedef BoardDecide = Future<void> Function(String sessionId, {required bool approve, required List<String> callIds});

/// How the Board answers approvals (cards, keys, Approve all); tests listen in here.
final boardDecideProvider = Provider<BoardDecide>(
  (ref) =>
      (sessionId, {required approve, required callIds}) => approve
      ? ref.read(codeSessionProvider(sessionId).notifier).approve(ApprovalScope.once, callIds)
      : ref.read(codeSessionProvider(sessionId).notifier).deny(null, callIds),
);

/// Sessions with an approve or deny from the Board in flight: one answer at a time each, whichever way it was asked
/// (a/d, the card's buttons, Approve all).
final boardDecidingProvider = Provider<Set<String>>((ref) => <String>{});

/// [decide] for [sessionId] unless an answer for it is already in flight; false when it was skipped. A harness that
/// answers whole batches would otherwise get a second answer landing on a newer batch nobody saw.
Future<bool> decideOnce(
  Set<String> deciding,
  BoardDecide decide,
  String sessionId, {
  required bool approve,
  required List<String> callIds,
}) async {
  if (!deciding.add(sessionId)) return false;
  try {
    await decide(sessionId, approve: approve, callIds: callIds);
    return true;
  } finally {
    deciding.remove(sessionId);
  }
}
