import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/preferences.dart';
import '../code_providers.dart' show codeSessionProvider;
import '../domain/code_session.dart';
import '../domain/doom_loop.dart';
import '../domain/transcript.dart';
import '../harness/events.dart' show ActionCall;
import 'board_providers.dart' show BoardColumn, boardDoneSinceProvider;

/// What a Board card says about its session, counting the work it runs besides the lead's own turn:
///
/// ```text
///            ┌───────────── the session or a child waits on the user ─────────────┐
///            │                                                                     ▼
///   working ─┴─lead idle, its forks / subagents / workflows still run─► waitingOnWork      needsYou
///      ▲                                   │                                                 │
///      │                                   └──── all of it ends ──► doneUnseen ──opened──► doneSeen
///      └──────────────── the lead (or its work) runs again ───────────────┘──────────────────┘
///   any of them ──broke, or its budget is spent──► failed
/// ```
///
/// Only [boardPhase] decides it, from the session's own status, its running work, whether a child waits on the user,
/// and whether the user has seen it since it finished.
enum BoardPhase {
  needsYou,
  working,
  waitingOnWork,
  failed,
  doneUnseen,
  doneSeen;

  BoardColumn get column => switch (this) {
    needsYou => BoardColumn.needsYou,
    working || waitingOnWork => BoardColumn.running,
    failed || doneUnseen || doneSeen => BoardColumn.done,
  };

  /// Its lead's turn or work it started still runs.
  bool get active => this == working || this == waitingOnWork;
}

/// What a session runs besides the lead's turn: forks and subagents that are sessions of ours (at any depth), an
/// outside lead's own subagents still out, and workflow runs. Commands and dev servers left running don't count.
typedef BoardWorkCount = ({int forks, int subagents, int workflows});

const noBoardWork = (forks: 0, subagents: 0, workflows: 0);

bool hasBoardWork(BoardWorkCount w) => w.forks + w.subagents + w.workflows > 0;

/// The card's phase. [own] is the session's own status; [seen] whether the user opened it since it finished.
BoardPhase boardPhase(
  SessionStatus own, {
  BoardWorkCount work = noBoardWork,
  bool childWaits = false,
  bool seen = false,
}) {
  if (own == SessionStatus.needsInput || childWaits) return BoardPhase.needsYou;
  // A failure shows even while its work still runs: Running would hide it.
  if (own == SessionStatus.failed) return BoardPhase.failed;
  if (own == SessionStatus.running || own == SessionStatus.starting || own == SessionStatus.paused) {
    return BoardPhase.working;
  }
  if (hasBoardWork(work)) return BoardPhase.waitingOnWork;
  return seen ? BoardPhase.doneSeen : BoardPhase.doneUnseen;
}

/// The card's status line for work in flight: "Lead waiting · 3 forks running", "Lead working · 1 subagent
/// running". Empty when the session runs nothing besides its lead.
String boardPhaseLine(BoardPhase phase, BoardWorkCount work) {
  if (!phase.active || !hasBoardWork(work)) return '';
  String n(int count, String one, String many) => '$count ${count == 1 ? one : many}';
  final parts = [
    if (work.forks > 0) '${n(work.forks, 'fork', 'forks')} running',
    if (work.subagents > 0) '${n(work.subagents, 'subagent', 'subagents')} running',
    if (work.workflows > 0) '${n(work.workflows, 'workflow', 'workflows')} running',
  ];
  return '${phase == BoardPhase.waitingOnWork ? 'Lead waiting' : 'Lead working'} · ${parts.join(' · ')}';
}

/// How many forks and subagents under [id] (sessions of ours, at any depth) are running.
int runningDescendants(
  String id,
  Map<String, List<CodeSessionInfo>> childrenOf,
  SessionStatus Function(CodeSessionInfo) statusOf, [
  Set<String>? seen,
]) {
  final visited = seen ?? <String>{};
  var n = 0;
  for (final c in childrenOf[id] ?? const <CodeSessionInfo>[]) {
    if (!visited.add(c.id)) continue;
    if (statusOf(c) == SessionStatus.running) n++;
    n += runningDescendants(c.id, childrenOf, statusOf, visited);
  }
  return n;
}

/// An outside lead's own subagents still out (Claude Code's agents, which aren't sessions of ours), by call id, with
/// what each was asked to do.
List<({String id, String task})> outsideSubagents(Transcript t) => [
  for (final i in t.items)
    if (i is SubagentItem && !i.ours && !i.done)
      (id: i.step.call.id, task: i.task.description.isNotEmpty ? i.task.description : i.step.call.summary),
];

/// Something about a running session the user may want to act on.
sealed class BoardWarning {
  const BoardWarning();

  String get line;
}

/// No new event for [minutes] while the lead works.
final class BoardStalled extends BoardWarning {
  const BoardStalled(this.minutes);
  final int minutes;

  @override
  String get line => 'No progress for $minutes min';
}

/// The same step [times] times in a row.
final class BoardLooping extends BoardWarning {
  const BoardLooping(this.step, {this.times = doomLoopRepeats});
  final String step;
  final int times;

  @override
  String get line => step.isEmpty ? 'Same step $times×' : 'Same step $times×: $step';
}

/// The lead's context is [percent] full.
final class BoardContextFull extends BoardWarning {
  const BoardContextFull(this.percent);
  final int percent;

  @override
  String get line => 'Context $percent%';
}

/// How long a working session may go without a new event before the card says so.
const boardStallAfter = Duration(minutes: 6);

/// How full the context gets before the card says so.
const boardContextWarnPercent = 90;

/// The warnings for a card: stalled ([sinceProgress] past [boardStallAfter]) and looping ([repeated], the step a run of
/// identical calls repeats) only while the lead works; a nearly full context ([contextPercent]) while anything runs or
/// waits on the user.
List<BoardWarning> boardWarnings({
  required BoardPhase phase,
  Duration sinceProgress = Duration.zero,
  String? repeated,
  int contextPercent = 0,
}) => [
  if (phase == BoardPhase.working && sinceProgress >= boardStallAfter) BoardStalled(sinceProgress.inMinutes),
  if (phase == BoardPhase.working && repeated != null) BoardLooping(repeated),
  if ((phase.active || phase == BoardPhase.needsYou) && contextPercent >= boardContextWarnPercent)
    BoardContextFull(contextPercent.clamp(0, 100)),
];

/// The step the transcript's last [times] tool calls repeat (identical tool and input, as the loop guard reads them),
/// or null when they don't.
String? repeatedStep(Transcript t, {int times = doomLoopRepeats}) {
  final calls = <ActionCall>[];
  for (final item in t.items) {
    switch (item) {
      case StepItem(:final step):
        calls.add(step.call);
      case ExploreGroup(:final steps):
        calls.addAll([for (final s in steps) s.call]);
      default:
        break;
    }
  }
  if (calls.length < times) return null;
  final tail = calls.sublist(calls.length - times);
  final sig = DoomLoopDetector.signature(tail.first);
  if (tail.any((c) => DoomLoopDetector.signature(c) != sig)) return null;
  return loopedStep(tail.last);
}

/// How full the context is, 0–100, from the last call's tokens and the model's window; 0 when either is unknown.
int contextPercent(int usedTokens, int window) =>
    window <= 0 || usedTokens <= 0 ? 0 : (usedTokens * 100 / window).round().clamp(0, 100);

/// When the user last looked at each session (epoch ms); Preferences `code.board.seen`. A finished session counts as
/// seen when this is at or after when it finished ([BoardDoneSince]).
final boardSeenProvider = NotifierProvider<BoardSeen, Map<String, int>>(BoardSeen.new);

final class BoardSeen extends Notifier<Map<String, int>> {
  static const key = 'code.board.seen';

  @override
  Map<String, int> build() {
    try {
      return {
        for (final e in (jsonDecode(ref.read(preferencesProvider)[key] ?? '{}') as Map<String, Object?>).entries)
          e.key: (e.value as num).toInt(),
      };
    } on Object {
      return const {};
    }
  }

  void _set(Map<String, int> next) {
    state = next;
    ref.read(preferencesProvider)[key] = jsonEncode(next);
  }

  /// The user is looking at [id] now.
  void see(String id, {DateTime? at}) => _set({...state, id: (at ?? DateTime.now()).millisecondsSinceEpoch});

  /// Drops the marks of sessions that run again, so their next finish is news.
  void forget(Iterable<String> ids) {
    if (!ids.any(state.containsKey)) return;
    _set({...state}..removeWhere((k, _) => ids.contains(k)));
  }
}

/// Whether a session that finished at [doneSince] has been seen since ([seenAt]).
bool seenSince(int? seenAt, DateTime? doneSince) =>
    seenAt != null && doneSince != null && seenAt >= doneSince.millisecondsSinceEpoch;

/// When an open session last showed progress: a new transcript item, streamed text, an approval or a status change.
/// The Board keeps it alive for open sessions and reads it on its clock ([boardWarnings]' stall check).
final boardProgressProvider = NotifierProvider.family<BoardProgress, DateTime, String>(BoardProgress.new);

final class BoardProgress extends Notifier<DateTime> {
  BoardProgress(this.sessionId);

  final String sessionId;

  @override
  DateTime build() {
    ref.listen(
      codeSessionProvider(sessionId).select(
        (s) => (
          s.transcript.items.length,
          s.transcript.streaming.length,
          s.transcript.streamingReasoning.length,
          s.transcript.pending.length,
          s.status,
        ),
      ),
      (_, _) => state = DateTime.now(),
    );
    return DateTime.now();
  }
}

/// The user is looking at session [id]: once it has [finished], that finish counts as seen on the Board (recorded,
/// if the Board hasn't yet); while it runs, an earlier mark is dropped so the next finish shows as new. Writes only
/// on a change.
void markBoardSeen(WidgetRef ref, String id, {required bool finished}) {
  final seenAt = ref.read(boardSeenProvider)[id];
  final since = ref.read(boardDoneSinceProvider);
  if (!finished) {
    if (seenAt != null) ref.read(boardSeenProvider.notifier).forget([id]);
    if (since?.containsKey(id) ?? false) ref.read(boardDoneSinceProvider.notifier).forget(id);
    return;
  }
  final now = DateTime.now();
  ref.read(boardDoneSinceProvider.notifier).mark(id, now);
  final doneAt = ref.read(boardDoneSinceProvider)?[id];
  if (seenAt == null || (doneAt != null && seenAt < doneAt)) ref.read(boardSeenProvider.notifier).see(id, at: now);
}
