import 'package:flutter/foundation.dart' show immutable;

import '../domain/code_session.dart';
import '../domain/transcript.dart';
import '../git/git_models.dart' show FileDiff;
import '../harness/events.dart' show ToolOutcome;
import 'board_plan.dart' show LeadPick, autonomousMode;

// Race: one prompt to two or more harnesses or models (as many as the user picks), each in its own worktree of the
// same project; compare what they did and keep one. Pure data and rules here; the notifier is in
// board_plan_providers.dart, the card and Compare view in board_plan_view.dart.

/// One runner of a race. Its session id is picked before anything starts, so a start the app quit during is found
/// again on the next launch ([recoverRunner]):
///
/// ```text
///   queued(session) ──its turn──► starting(session) ──started──► running(session) ◄──works again──┐
///      │                               │                            ├──finished──► done(session, at) ┘
///      │                               │                            └──failed──► failed(why, session)
///      │                               └──couldn't start──► failed(why)
///      │                               └──race cancelled with Stop──► stopping(session) ──exists──► discarded
///      └──race cancelled (or removed)──► discarded
///   running / done ──its session was deleted──► gone(session)
///   running / done / failed ──another runner was kept, or Stop and remove──► discarded (worktree removed, branch kept)
/// ```
sealed class RunnerRun {
  const RunnerRun();
}

/// Waiting for its turn (runners start one at a time, so worktrees aren't made on one repository at once).
final class RunnerQueued extends RunnerRun {
  const RunnerQueued(this.sessionId);
  final String sessionId;
}

final class RunnerStarting extends RunnerRun {
  const RunnerStarting(this.sessionId);
  final String sessionId;
}

/// The race was cancelled with Stop while this runner's session was being made: stopped and removed once it exists.
final class RunnerStopping extends RunnerRun {
  const RunnerStopping(this.sessionId);
  final String sessionId;
}

final class RunnerRunning extends RunnerRun {
  const RunnerRunning(this.sessionId);
  final String sessionId;
}

final class RunnerDone extends RunnerRun {
  const RunnerDone(this.sessionId, this.at);
  final String sessionId;

  /// When the race first saw it finished (its wall time ends here).
  final DateTime at;
}

final class RunnerFailed extends RunnerRun {
  const RunnerFailed(this.why, {this.sessionId});
  final String why;
  final String? sessionId;
}

/// Its session was deleted outside the race: shown as gone, never kept.
final class RunnerGone extends RunnerRun {
  const RunnerGone(this.sessionId);
  final String sessionId;
}

final class RunnerDiscarded extends RunnerRun {
  const RunnerDiscarded();
}

/// The session a runner's card points at (none once it is queued, being made, gone or removed).
String? sessionOfRunner(RunnerRun run) => switch (run) {
  RunnerRunning(:final sessionId) || RunnerDone(:final sessionId) => sessionId,
  RunnerFailed(:final sessionId) => sessionId,
  RunnerQueued() || RunnerStarting() || RunnerStopping() || RunnerGone() || RunnerDiscarded() => null,
};

/// Whether [run]'s session is still being made (its start is in flight).
bool runnerPending(RunnerRun run) => run is RunnerStarting || run is RunnerStopping;

/// Whether [run] is over for now (it changes only if its session works again or is deleted).
bool runnerFinished(RunnerRun run) =>
    run is RunnerDone || run is RunnerFailed || run is RunnerGone || run is RunnerDiscarded;

/// What a runner the app quit during comes back as, given whether its chosen session exists ([exists]): a start
/// that saved its session is running; one that didn't never ran (nothing to stop, nothing started twice); one the
/// user had stopped is removed (the notifier removes its session when it was made). A runner still queued stays
/// queued (the notifier starts it).
RunnerRun recoverRunner(RunnerRun run, {required bool Function(String sessionId) exists}) => switch (run) {
  RunnerStarting(:final sessionId) when exists(sessionId) => RunnerRunning(sessionId),
  RunnerStarting() => const RunnerFailed('EveryAI closed before this runner\'s session was made.'),
  RunnerStopping() => const RunnerDiscarded(),
  _ => run,
};

@immutable
final class RaceRunner {
  const RaceRunner({required this.lead, required this.run, this.startedAt});

  final LeadPick lead;
  final RunnerRun run;
  final DateTime? startedAt;

  RaceRunner copyWith({RunnerRun? run, DateTime? startedAt}) =>
      RaceRunner(lead: lead, run: run ?? this.run, startedAt: startedAt ?? this.startedAt);

  Map<String, Object?> toJson() => {
    'harness': lead.harness,
    'model': lead.model,
    'started': ?startedAt?.millisecondsSinceEpoch,
    'run': switch (run) {
      RunnerQueued(:final sessionId) => {'s': 'queued', 'session': sessionId},
      RunnerStarting(:final sessionId) => {'s': 'starting', 'session': sessionId},
      RunnerStopping(:final sessionId) => {'s': 'stopping', 'session': sessionId},
      RunnerRunning(:final sessionId) => {'s': 'running', 'session': sessionId},
      RunnerDone(:final sessionId, :final at) => {'s': 'done', 'session': sessionId, 'at': at.millisecondsSinceEpoch},
      RunnerFailed(:final why, :final sessionId) => {'s': 'failed', 'why': why, 'session': ?sessionId},
      RunnerGone(:final sessionId) => {'s': 'gone', 'session': sessionId},
      RunnerDiscarded() => {'s': 'discarded'},
    },
  };

  static RaceRunner? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final run = json['run'] as Map<String, Object?>? ?? const {};
    final session = run['session'] as String?;
    return RaceRunner(
      lead: (harness: json['harness'] as String? ?? '', model: json['model'] as String? ?? ''),
      startedAt: switch (json['started']) {
        final num ms => DateTime.fromMillisecondsSinceEpoch(ms.toInt()),
        _ => null,
      },
      run: switch (run['s']) {
        'queued' when session != null => RunnerQueued(session),
        'starting' when session != null => RunnerStarting(session),
        'stopping' when session != null => RunnerStopping(session),
        'running' when session != null => RunnerRunning(session),
        'done' when session != null => RunnerDone(
          session,
          DateTime.fromMillisecondsSinceEpoch((run['at'] as num?)?.toInt() ?? 0),
        ),
        'failed' => RunnerFailed(run['why'] as String? ?? 'Failed.', sessionId: session),
        'gone' when session != null => RunnerGone(session),
        'discarded' => const RunnerDiscarded(),
        // A start saved before its session id was kept: whether it started is unknown.
        _ => const RunnerFailed('EveryAI closed while this runner was starting.'),
      },
    );
  }
}

/// Where a race is:
///
/// ```text
///   starting ──every runner started (or couldn't)──► running ──every runner finished──► comparing
///                                                       └────────── Compare now ──────────┘
///   comparing / running ──Keep(winner)──► keeping(winner, merging) ──merged──► keeping(winner, removingLosers)
///                                                └──not merged──► comparing        └──losers removed──► kept(winner)
///   any but kept ──Cancel──► cancelled
///   any ──Remove──► removing (hidden until its runners' sessions exist) ──► gone from the list
/// ```
///
/// [RaceRunning] ↔ [RaceComparing] follows the runners ([settleRace]); the user moves it on Compare now, Keep, Cancel
/// and Remove. [RaceKeeping] is the provider's, so a Keep survives the lane being rebuilt and the app quitting
/// ([BoardRaces] resumes it on load).
sealed class RaceStage {
  const RaceStage();

  /// The stored name.
  String get name;

  /// Runners still at work or starting (the card glows, × asks first).
  bool get live => this is RaceStarting || this is RaceRunning;
}

final class RaceStarting extends RaceStage {
  const RaceStarting();
  @override
  String get name => 'starting';
}

final class RaceRunning extends RaceStage {
  const RaceRunning();
  @override
  String get name => 'running';
}

final class RaceComparing extends RaceStage {
  const RaceComparing();
  @override
  String get name => 'comparing';
}

/// What a Keep is doing.
enum KeepStep { merging, removingLosers }

final class RaceKeeping extends RaceStage {
  const RaceKeeping(this.winner, this.step);
  final String winner;
  final KeepStep step;
  @override
  String get name => 'keeping';
}

final class RaceKept extends RaceStage {
  const RaceKept(this.winner);
  final String winner;
  @override
  String get name => 'kept';
}

final class RaceCancelled extends RaceStage {
  const RaceCancelled();
  @override
  String get name => 'cancelled';
}

/// Removed by the user while a runner's session was still being made: hidden, dropped once none is.
final class RaceRemoving extends RaceStage {
  const RaceRemoving();
  @override
  String get name => 'removing';
}

/// The races the lane shows: a removed one still waiting on a start is hidden.
List<BoardRace> shownRaces(List<BoardRace> races) => [
  for (final r in races)
    if (r.stage is! RaceRemoving) r,
];

/// The session the race kept or is keeping.
String? winnerOf(RaceStage stage) => switch (stage) {
  RaceKeeping(:final winner) || RaceKept(:final winner) => winner,
  _ => null,
};

Map<String, Object?> _stageToJson(RaceStage stage) => {
  's': stage.name,
  if (stage case RaceKeeping(:final winner, :final step)) ...{'winner': winner, 'step': step.name},
  if (stage case RaceKept(:final winner)) 'winner': winner,
};

RaceStage _stageFromJson(Object? json, {String? legacyKept}) {
  final m = json is Map<String, Object?> ? json : <String, Object?>{'s': json};
  final winner = m['winner'] as String? ?? legacyKept;
  return switch (m['s']) {
    'starting' => const RaceStarting(),
    'comparing' => const RaceComparing(),
    'keeping' when winner != null => RaceKeeping(winner, KeepStep.values.asNameMap()[m['step']] ?? KeepStep.merging),
    'kept' when winner != null => RaceKept(winner),
    'cancelled' => const RaceCancelled(),
    'removing' => const RaceRemoving(),
    _ => const RaceRunning(),
  };
}

@immutable
final class BoardRace {
  const BoardRace({
    required this.id,
    required this.projectId,
    required this.prompt,
    required this.runners,
    required this.createdAt,
    this.stage = const RaceStarting(),
    this.goalId,
    this.mode = autonomousMode,
  });

  final String id;
  final String projectId;
  final String prompt;
  final List<RaceRunner> runners;
  final RaceStage stage;
  final DateTime createdAt;

  /// The goal it was raced from, if any.
  final String? goalId;

  /// The mode its runners start in (an AgentMode name, or [autonomousMode]: the most autonomous each lead allows).
  final String mode;

  BoardRace copyWith({List<RaceRunner>? runners, RaceStage? stage}) => BoardRace(
    id: id,
    projectId: projectId,
    prompt: prompt,
    runners: runners ?? this.runners,
    createdAt: createdAt,
    stage: stage ?? this.stage,
    goalId: goalId,
    mode: mode,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'project': projectId,
    'prompt': prompt,
    'runners': [for (final r in runners) r.toJson()],
    'stage': _stageToJson(stage),
    'created': createdAt.millisecondsSinceEpoch,
    'goal': ?goalId,
    'mode': mode,
  };

  static BoardRace? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final id = json['id'];
    final project = json['project'];
    if (id is! String || project is! String) return null;
    final runners = [for (final r in json['runners'] as List<Object?>? ?? const []) ?RaceRunner.fromJson(r)];
    return BoardRace(
      id: id,
      projectId: project,
      prompt: json['prompt'] as String? ?? '',
      runners: runners,
      createdAt: DateTime.fromMillisecondsSinceEpoch((json['created'] as num?)?.toInt() ?? 0),
      stage: _stageFromJson(json['stage'], legacyKept: json['kept'] as String?),
      goalId: json['goal'] as String?,
      mode: json['mode'] as String? ?? autonomousMode,
    );
  }
}

/// The stage [race]'s runners put it in: still starting while any runner waits or starts; comparing once every
/// runner has finished; else running. Keeping, kept, cancelled and removing races, and ones the user moved to
/// comparing, keep theirs.
RaceStage settleRace(BoardRace race) {
  switch (race.stage) {
    case RaceKeeping() || RaceKept() || RaceCancelled() || RaceRemoving() || RaceComparing():
      return race.stage;
    case RaceStarting() || RaceRunning():
  }
  if (race.runners.any((r) => r.run is RunnerQueued || r.run is RunnerStarting)) return const RaceStarting();
  if (race.runners.isNotEmpty && race.runners.every((r) => runnerFinished(r.run))) return const RaceComparing();
  return const RaceRunning();
}

/// The runners a new race starts with: the two (harness, model) pairs the user started most top-level sessions with
/// (newest breaks a tie), among the harnesses [usable] allows; [fallback] fills the rest. At most [count].
List<LeadPick> defaultRunners(
  List<CodeSessionInfo> sessions, {
  required bool Function(String harness) usable,
  required List<LeadPick> fallback,
  int count = 2,
}) {
  final counts = <LeadPick, ({int n, DateTime last})>{};
  for (final s in sessions) {
    if (s.parentId != null || !usable(s.harness)) continue;
    final key = (harness: s.harness, model: s.model);
    final was = counts[key];
    counts[key] = (n: (was?.n ?? 0) + 1, last: was == null || s.createdAt.isAfter(was.last) ? s.createdAt : was.last);
  }
  final ranked = counts.entries.toList()
    ..sort((a, b) => b.value.n != a.value.n ? b.value.n.compareTo(a.value.n) : b.value.last.compareTo(a.value.last));
  final out = <LeadPick>[for (final e in ranked) e.key];
  for (final f in fallback) {
    if (!out.contains(f) && usable(f.harness)) out.add(f);
  }
  return out.take(count).toList();
}

/// Whether the runner's tests passed, as best its transcript shows: the last command that looks like a test run.
enum RunnerTests { passed, failed, notRun }

final _testCommand = RegExp(
  r'(^|[\s;&|(])(pytest|jest|vitest|rspec|phpunit|tox|nox|ctest|(go|cargo|flutter|dart|deno|bun|swift|mix|zig|mvn|gradle|\./gradlew|dotnet) test|(npm|pnpm|yarn)( run)? test|make (test|check))\b',
);

/// [RunnerTests] from [t]: the last finished test-looking command, passed when it succeeded.
RunnerTests testsOf(Transcript? t) {
  if (t == null) return RunnerTests.notRun;
  var result = RunnerTests.notRun;
  void look(ToolStep step) {
    final command = step.call.str('command');
    if (command.isEmpty || !_testCommand.hasMatch(command)) return;
    final r = step.result;
    if (r == null) return;
    result = r.outcome == ToolOutcome.ok ? RunnerTests.passed : RunnerTests.failed;
  }

  for (final item in t.items) {
    switch (item) {
      case StepItem(:final step):
        look(step);
      case ExploreGroup(:final steps):
        steps.forEach(look);
      case _:
    }
  }
  return result;
}

/// One runner's numbers for the Compare view.
typedef RunnerStats = ({int files, int added, int removed, RunnerTests tests, Duration? wall});

/// [RunnerStats] from its worktree's diff ([files], null when not read), its transcript and when it ran.
RunnerStats runnerStats({
  required List<FileDiff>? files,
  required Transcript? transcript,
  required DateTime? startedAt,
  required RunnerRun run,
}) => (
  files: files?.length ?? 0,
  added: files?.fold<int>(0, (n, f) => n + f.added) ?? 0,
  removed: files?.fold<int>(0, (n, f) => n + f.removed) ?? 0,
  tests: testsOf(transcript),
  wall: switch ((startedAt, run)) {
    (final from?, RunnerDone(:final at)) => at.difference(from),
    _ => null,
  },
);

/// "4 min", "1 h 12 min", "40 s".
String wallText(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds.clamp(0, 59)} s';
  if (d.inMinutes < 60) return '${d.inMinutes} min';
  return '${d.inHours} h ${d.inMinutes % 60} min';
}
