import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../code_providers.dart' show codeSessionProvider;
import '../domain/code_session.dart';
import '../domain/doom_loop.dart';
import '../domain/transcript.dart';
import '../harness/events.dart' show ActionCall;
import '../shells/shell_registry.dart' show ShellRegistry;
import 'board_providers.dart' show BoardColumn, Looked, Ran, boardMarksProvider;

/// What a Board card says about its session, counting the work it runs besides the lead's own turn:
///
/// ```text
///            ┌───────────── the session or a child waits on the user ─────────────┐
///            │                                                                     ▼
///   working ─┴─lead idle, its forks / subagents / workflows still run─► waitingOnWork      needsYou
///    ▲   │                                 │                                                 │
///    │   └─Pause─► paused ─Resume─► working└──── all of it ends ──► doneUnseen ──opened──► doneSeen
///    └──────────────── the lead (or its work) runs again ───────────────┘──────────────────┘
///   any of them ──broke, or its budget is spent──► failed
/// ```
///
/// Only [boardPhase] decides it, from the session's own status, its running work, whether a child waits on the user,
/// and whether the user has seen it since it finished. A paused session sits in Running without glow or stall
/// warnings: the user stopped it on purpose.
enum BoardPhase {
  needsYou,
  working,
  waitingOnWork,
  paused,
  failed,
  doneUnseen,
  doneSeen;

  BoardColumn get column => switch (this) {
    needsYou => BoardColumn.needsYou,
    working || waitingOnWork || paused => BoardColumn.running,
    failed || doneUnseen || doneSeen => BoardColumn.done,
  };

  /// Its lead's turn or work it started still runs (not paused).
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
  if (own == SessionStatus.paused) return BoardPhase.paused;
  if (own == SessionStatus.running || own == SessionStatus.starting) return BoardPhase.working;
  if (hasBoardWork(work)) return BoardPhase.waitingOnWork;
  return seen ? BoardPhase.doneSeen : BoardPhase.doneUnseen;
}

/// The card's status line for work in flight: "Lead waiting · 3 forks running", "Lead working · 1 subagent
/// running". Empty when the session runs nothing besides its lead.
String boardPhaseLine(BoardPhase phase, BoardWorkCount work) {
  if (phase == BoardPhase.paused) return 'Paused';
  if (!phase.active || !hasBoardWork(work)) return '';
  String n(int count, String one, String many) => '$count ${count == 1 ? one : many}';
  final parts = [
    if (work.forks > 0) '${n(work.forks, 'fork', 'forks')} running',
    if (work.subagents > 0) '${n(work.subagents, 'subagent', 'subagents')} running',
    if (work.workflows > 0) '${n(work.workflows, 'workflow', 'workflows')} running',
  ];
  return '${phase == BoardPhase.waitingOnWork ? 'Lead waiting' : 'Lead working'} · ${parts.join(' · ')}';
}

/// Child statuses that are still work for their lead: running, starting, paused (it resumes), or waiting (on the user,
/// which [boardPhase] shows as Needs you first, or on the lead, which answers it).
const _childWorking = {SessionStatus.running, SessionStatus.starting, SessionStatus.paused, SessionStatus.needsInput};

/// How many forks and subagents under [id] (sessions of ours, at any depth) are still work ([_childWorking]). A child
/// waiting on the user counts only while it is open ([isOpen]): a closed one's polled wait is the user's to answer
/// (the Board opens it so its card shows the question), not work for its lead.
int runningDescendants(
  String id,
  Map<String, List<CodeSessionInfo>> childrenOf,
  SessionStatus Function(CodeSessionInfo) statusOf, {
  bool Function(CodeSessionInfo) isOpen = _alwaysOpen,
  Set<String>? seen,
}) {
  final visited = seen ?? <String>{};
  var n = 0;
  for (final c in childrenOf[id] ?? const <CodeSessionInfo>[]) {
    if (!visited.add(c.id)) continue;
    final st = statusOf(c);
    if (_childWorking.contains(st) && (st != SessionStatus.needsInput || isOpen(c))) n++;
    n += runningDescendants(c.id, childrenOf, statusOf, isOpen: isOpen, seen: visited);
  }
  return n;
}

bool _alwaysOpen(CodeSessionInfo _) => true;

/// The descendants of [id] (any depth) whose polled status says they wait on the user and that aren't open: the
/// Board opens them so their card shows the wait.
List<CodeSessionInfo> closedWaiting(
  String id,
  Map<String, List<CodeSessionInfo>> childrenOf,
  SessionStatus Function(CodeSessionInfo) statusOf,
  bool Function(CodeSessionInfo) isOpen, [
  Set<String>? seen,
]) {
  final visited = seen ?? <String>{};
  return [
    for (final c in childrenOf[id] ?? const <CodeSessionInfo>[])
      if (visited.add(c.id)) ...[
        if (statusOf(c) == SessionStatus.needsInput && !isOpen(c)) c,
        ...closedWaiting(c.id, childrenOf, statusOf, isOpen, visited),
      ],
  ];
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

/// The warnings for a card: stalled ([sinceProgress] past [boardStallAfter]; only once [connected], so a session still
/// connecting isn't "stalled") and looping ([repeated], the step a run of identical calls repeats) only while the lead
/// works; a nearly full context ([contextPercent]) while anything runs or waits on the user. A paused session gets
/// none of the first two: the user stopped it on purpose.
List<BoardWarning> boardWarnings({
  required BoardPhase phase,
  Duration sinceProgress = Duration.zero,
  String? repeated,
  int contextPercent = 0,
  bool connected = true,
}) => [
  if (phase == BoardPhase.working && connected && sinceProgress >= boardStallAfter)
    BoardStalled(sinceProgress.inMinutes),
  if (phase == BoardPhase.working && repeated != null) BoardLooping(repeated),
  if ((phase.active || phase == BoardPhase.needsYou) && contextPercent >= boardContextWarnPercent)
    BoardContextFull(contextPercent.clamp(0, 100)),
];

/// The step the transcript's last [times] tool calls repeat (identical tool and input), or null. It reads the calls
/// the loop guard counts ([DoomLoopDetector.counts]) and starts over when the user speaks, as the guard does.
String? repeatedStep(Transcript t, {int times = doomLoopRepeats}) {
  var calls = <ActionCall>[];
  for (final item in t.items) {
    switch (item) {
      case UserTurn():
        calls = [];
      case StepItem(:final step):
        calls.add(step.call);
      case ExploreGroup(:final steps):
        calls.addAll([for (final s in steps) s.call]);
      default:
        break;
    }
  }
  final looped = DoomLoopDetector.loopAtEnd(calls, times: times);
  return looped == null ? null : loopedStep(looped);
}

/// How full the context is, 0–100, from the last call's tokens and the model's window; 0 when either is unknown.
int contextPercent(int usedTokens, int window) =>
    window <= 0 || usedTokens <= 0 ? 0 : (usedTokens * 100 / window).round().clamp(0, 100);

/// What [BoardProgress] has seen of a session's running commands: nothing yet, or their output size and when it
/// last grew.
sealed class _ShellWatch {
  const _ShellWatch();
}

final class _NoShellLook extends _ShellWatch {
  const _NoShellLook();
}

final class _ShellLook extends _ShellWatch {
  const _ShellLook(this.bytes, this.changedAt);
  final int bytes;
  final DateTime changedAt;
}

/// When an open session last showed progress: a new transcript item, streamed text, an approval or a status change.
/// A card watches it while it shows (it goes with the card) and reads [BoardProgress.last] on its clock
/// ([boardWarnings]' stall check), which also counts output of the session's running commands.
final boardProgressProvider = NotifierProvider.autoDispose.family<BoardProgress, DateTime, String>(BoardProgress.new);

final class BoardProgress extends Notifier<DateTime> {
  BoardProgress(this.sessionId, {ShellRegistry? shells}) : _shells = shells ?? ShellRegistry.instance;

  final String sessionId;
  final ShellRegistry _shells;

  /// Bytes the session's running foreground commands had written at the last look, and when that last grew. A long
  /// build or test run writes as it goes, so it isn't a stall. Background shells (dev servers) don't count: their
  /// logs say nothing about the lead.
  _ShellWatch _watch = const _NoShellLook();

  /// The latest progress, counting command output seen since the last look. Read on the card's clock.
  DateTime last() {
    var bytes = 0;
    for (final e in _shells.of(sessionId)) {
      if (e.running && !e.background) bytes += e.logged;
    }
    final look = _watch;
    final at = switch (look) {
      _ShellLook(bytes: final b, :final changedAt) when b == bytes => changedAt,
      // The first look, or the output grew: progress now.
      _ => DateTime.now(),
    };
    if (look is! _ShellLook || look.bytes != bytes) _watch = _ShellLook(bytes, at);
    return state.isAfter(at) ? state : at;
  }

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

/// What looking at a session means for its Board marks ([markBoardSeen]): nothing yet (it hasn't connected, or is
/// starting: its status says nothing about the last finish), it runs (drop the marks), or it finished (seen).
enum SeenUpdate { none, running, finished }

/// [markBoardSeen]'s reading of a session the user is looking at.
SeenUpdate seenUpdate({required SessionStatus status, required bool connected, required bool sideWork}) {
  if (!connected) return SeenUpdate.none;
  return switch (status) {
    SessionStatus.starting => SeenUpdate.none,
    SessionStatus.running || SessionStatus.needsInput || SessionStatus.paused => SeenUpdate.running,
    SessionStatus.idle ||
    SessionStatus.done ||
    SessionStatus.failed => sideWork ? SeenUpdate.running : SeenUpdate.finished,
  };
}

/// The user is looking at session [id]: once it has finished, that finish counts as seen on the Board (recorded, if
/// the Board hasn't yet); while it runs, the marks are dropped so the next finish shows as new. Until it has
/// connected nothing changes, so opening an old finished session keeps when it finished. The marks' one writer moves
/// the state and writes only when it changes, so calling this on every build is free.
void markBoardSeen(WidgetRef ref, String id, SeenUpdate update) {
  final event = switch (update) {
    SeenUpdate.none => null,
    SeenUpdate.running => const Ran(),
    SeenUpdate.finished => Looked(DateTime.now()),
  };
  if (event != null) ref.read(boardMarksProvider.notifier).apply(id, event);
}
