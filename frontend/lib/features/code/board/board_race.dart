import 'package:flutter/foundation.dart' show immutable;

import '../domain/code_session.dart';
import '../domain/transcript.dart';
import '../git/git_models.dart' show FileDiff;
import '../harness/events.dart' show ToolOutcome;
import 'board_plan.dart' show LeadPick;

// Race: one prompt to 2–4 harnesses or models, each in its own worktree of the same project; compare what they did
// and keep one. Pure data and rules here; the notifier is in board_plan_providers.dart, the card and Compare view in
// board_plan_view.dart.

/// One runner of a race:
///
/// ```text
///   starting ──started──► running(session) ──its session finished──► done(session, at)
///      │                        └──its session failed──► failed(why, session)
///      └──couldn't start──► failed(why)
///   done / failed / running ──another runner was kept──► discarded
/// ```
sealed class RunnerRun {
  const RunnerRun();
}

final class RunnerStarting extends RunnerRun {
  const RunnerStarting();
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

final class RunnerDiscarded extends RunnerRun {
  const RunnerDiscarded();
}

String? sessionOfRunner(RunnerRun run) => switch (run) {
  RunnerRunning(:final sessionId) || RunnerDone(:final sessionId) => sessionId,
  RunnerFailed(:final sessionId) => sessionId,
  RunnerStarting() || RunnerDiscarded() => null,
};

/// Whether [run] is over (it won't change by itself).
bool runnerFinished(RunnerRun run) => run is RunnerDone || run is RunnerFailed || run is RunnerDiscarded;

@immutable
final class RaceRunner {
  const RaceRunner({required this.lead, this.run = const RunnerStarting(), this.startedAt});

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
      RunnerStarting() => {'s': 'starting'},
      RunnerRunning(:final sessionId) => {'s': 'running', 'session': sessionId},
      RunnerDone(:final sessionId, :final at) => {'s': 'done', 'session': sessionId, 'at': at.millisecondsSinceEpoch},
      RunnerFailed(:final why, :final sessionId) => {'s': 'failed', 'why': why, 'session': ?sessionId},
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
        'running' when session != null => RunnerRunning(session),
        'done' when session != null => RunnerDone(
          session,
          DateTime.fromMillisecondsSinceEpoch((run['at'] as num?)?.toInt() ?? 0),
        ),
        'failed' => RunnerFailed(run['why'] as String? ?? 'Failed.', sessionId: session),
        'discarded' => const RunnerDiscarded(),
        // A start the app quit during: maybe it started, maybe not.
        _ => const RunnerFailed('EveryAI closed while this runner was starting.'),
      },
    );
  }
}

/// Where a race is:
///
/// ```text
///   starting ──every runner started (or couldn't)──► running ──every runner finished──► comparing ──Keep──► kept
///                                                       └────────── Compare now ──────────┘
///   any ──Cancel──► cancelled
/// ```
///
/// [running] → [comparing] follows the runners ([settleRace]); the user moves it on Compare now, Keep and Cancel.
enum RaceStage { starting, running, comparing, kept, cancelled }

@immutable
final class BoardRace {
  const BoardRace({
    required this.id,
    required this.projectId,
    required this.prompt,
    required this.runners,
    required this.createdAt,
    this.stage = RaceStage.starting,
    this.keptSession,
    this.goalId,
  });

  final String id;
  final String projectId;
  final String prompt;
  final List<RaceRunner> runners;
  final RaceStage stage;
  final DateTime createdAt;

  /// The runner's session the user kept.
  final String? keptSession;

  /// The goal it was raced from, if any.
  final String? goalId;

  BoardRace copyWith({List<RaceRunner>? runners, RaceStage? stage, String? keptSession}) => BoardRace(
    id: id,
    projectId: projectId,
    prompt: prompt,
    runners: runners ?? this.runners,
    createdAt: createdAt,
    stage: stage ?? this.stage,
    keptSession: keptSession ?? this.keptSession,
    goalId: goalId,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'project': projectId,
    'prompt': prompt,
    'runners': [for (final r in runners) r.toJson()],
    'stage': stage.name,
    'created': createdAt.millisecondsSinceEpoch,
    'kept': ?keptSession,
    'goal': ?goalId,
  };

  static BoardRace? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final id = json['id'];
    final project = json['project'];
    if (id is! String || project is! String) return null;
    final runners = [for (final r in json['runners'] as List<Object?>? ?? const []) ?RaceRunner.fromJson(r)];
    final stage = RaceStage.values.asNameMap()[json['stage']] ?? RaceStage.running;
    return BoardRace(
      id: id,
      projectId: project,
      prompt: json['prompt'] as String? ?? '',
      runners: runners,
      createdAt: DateTime.fromMillisecondsSinceEpoch((json['created'] as num?)?.toInt() ?? 0),
      stage: stage == RaceStage.starting ? RaceStage.running : stage,
      keptSession: json['kept'] as String?,
      goalId: json['goal'] as String?,
    );
  }
}

/// The stage [race]'s runners put it in: still starting while any runner starts; comparing once every runner has
/// finished; else running. Kept and cancelled races, and ones the user moved to comparing, keep theirs.
RaceStage settleRace(BoardRace race) {
  switch (race.stage) {
    case RaceStage.kept || RaceStage.cancelled || RaceStage.comparing:
      return race.stage;
    case RaceStage.starting || RaceStage.running:
  }
  if (race.runners.any((r) => r.run is RunnerStarting)) return RaceStage.starting;
  if (race.runners.isNotEmpty && race.runners.every((r) => runnerFinished(r.run))) return RaceStage.comparing;
  return RaceStage.running;
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
