import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/features/code/board/board_plan.dart';
import 'package:every_ai/features/code/board/board_plan_providers.dart';
import 'package:every_ai/features/code/board/board_planner.dart';
import 'package:every_ai/features/code/board/board_race.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/harness/harness.dart' show HarnessError;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// The Plan lane and Race: the split's reading, dependency order, the plan and race state machines, and their
// notifiers with a fake planner and starter.

const _leads = <PlannerLead>[
  (id: 'alpha', label: 'Alpha', models: ['a1', 'a2']),
  (id: 'beta', label: 'Beta', models: []),
];
const _fallback = (harness: 'alpha', model: '');

PlanSplit _parse(String reply) {
  var n = 0;
  return parsePlanSplit(reply, leads: _leads, fallback: _fallback, newId: () => 't${++n}');
}

GoalTask _t(String id, {List<String> after = const [], TaskRun run = const TaskDraft()}) =>
    GoalTask(id: id, title: 'Task $id', lead: _fallback, after: after, run: run);

PlanGoal _g(List<GoalTask> tasks, {GoalStage stage = GoalStage.ready}) => PlanGoal(
  id: 'g',
  projectId: 'p1',
  planner: _fallback,
  createdAt: DateTime(2026, 11, 11),
  text: 'Ship it',
  tasks: tasks,
  stage: stage,
);

/// A planner that answers [reply] (or throws [error]) after [gate] opens.
final class _Planner implements BoardPlanner {
  String reply = '';
  Object? error;
  Completer<void>? gate;
  final asked = <(LeadPick, String)>[];

  @override
  String? unavailable(LeadPick pick) => pick.harness == 'off' ? 'Not installed' : null;

  /// Set when the planner was told to stop.
  var cancelled = false;

  @override
  Future<String> ask(
    LeadPick pick,
    String prompt, {
    required CodeProject project,
    required String tag,
    Future<void>? cancel,
  }) async {
    asked.add((pick, prompt));
    unawaited(cancel?.then((_) => cancelled = true));
    await gate?.future;
    if (error case final e?) throw e;
    return reply;
  }
}

/// A starter whose session ids are `s-<n>` in the order they are picked; it records each start (and the session as
/// existing); [fail] names prompts that fail to start; [gate] holds starts; [handoffs] are the commits of sessions'
/// work (none: it ran in the project folder); [landedSessions] have merged.
final class _Starter implements BoardStarter {
  final started = <({String id, String prompt, LeadPick lead, bool worktree, AgentMode mode, String? from})>[];
  final existing = <String>{};
  final landedSessions = <String>{};
  var _ids = 0;
  final fail = <String>{};
  Completer<void>? gate;
  final handoffs = <String, String>{};
  final stopped = <String>[];
  final discarded = <String>[];

  /// Starts that ran at the same time as another, at most.
  var overlap = 0;
  var _running = 0;

  @override
  String newSessionId() => 's-${++_ids}';

  @override
  bool exists(String sessionId) => existing.contains(sessionId);

  @override
  Future<bool> landed(String sessionId) async => landedSessions.contains(sessionId);

  @override
  Future<void> start({
    required String sessionId,
    required CodeProject project,
    required String prompt,
    required LeadPick lead,
    required bool worktree,
    required AgentMode mode,
    String? fromCommit,
  }) async {
    _running++;
    if (_running > overlap) overlap = _running;
    try {
      await gate?.future;
      await Future<void>.delayed(Duration.zero);
      if (fail.any(prompt.startsWith)) throw const HarnessError('No room.');
      started.add((id: sessionId, prompt: prompt, lead: lead, worktree: worktree, mode: mode, from: fromCommit));
      existing.add(sessionId);
    } finally {
      _running--;
    }
  }

  @override
  Future<String?> handoff(String sessionId) async => handoffs[sessionId];

  @override
  Future<void> stop(String sessionId) async => stopped.add(sessionId);

  @override
  Future<void> discard(String sessionId) async => discarded.add(sessionId);
}

void main() {
  group('the split', () {
    test('reads the first JSON object, maps "after" numbers to ids, and checks harnesses and models', () {
      final split = _parse('''
Here is the plan:
```json
{"tasks":[
  {"title":"API routes","brief":"Add /v1/bills.","after":[],"harness":"beta","model":""},
  {"title":"UI","brief":"Bills page {with braces}.","after":[1],"harness":"alpha","model":"a2"},
  {"title":"Tests","brief":"","after":[1,2,2],"harness":"nope","model":"a1"}
]}
```''');
      final tasks = (split as SplitTasks).tasks;
      expect([for (final t in tasks) t.title], ['API routes', 'UI', 'Tests']);
      expect(tasks[1].brief, 'Bills page {with braces}.');
      expect(
        [for (final t in tasks) t.after],
        [
          <String>[],
          ['t1'],
          ['t1', 't2'],
        ],
      );
      expect(
        [for (final t in tasks) t.lead],
        [
          (harness: 'beta', model: ''),
          (harness: 'alpha', model: 'a2'),
          // An unknown harness falls back to the default lead.
          _fallback,
        ],
      );
      expect(tasks.every((t) => t.worktree && t.run is TaskDraft), isTrue);
    });

    test('takes any number of tasks; refuses replies without tasks, bad dependencies or a loop', () {
      String why(String reply) => (_parse(reply) as SplitRefused).why;
      expect(why('Sorry, I cannot help.'), contains('no tasks'));
      // No count cap either way (owner).
      expect((_parse('{"tasks":[{"title":"Only one"}]}') as SplitTasks).tasks, hasLength(1));
      final many = _parse(
        jsonEncode({
          'tasks': List.generate(40, (i) => {'title': 'T$i'}),
        }),
      );
      expect((many as SplitTasks).tasks, hasLength(40));
      expect(why('{"tasks":[{"title":"A","after":[2]},{"title":"B","after":[1]}]}'), contains('loop'));
      expect(why('{"tasks":[{"title":"A","after":[1]},{"title":"B"}]}'), contains('itself'));
      expect(why('{"tasks":[{"title":"A","after":[5]},{"title":"B"}]}'), contains("isn't there"));
      expect(why('{"tasks":[{"title":""},{"title":"B"}]}'), contains('no title'));
    });
  });

  group('order and stages', () {
    test('a task starts once every task it waits for is done; a failed one blocks what waits on it', () {
      var g = _g([
        _t('a', run: const TaskQueued()),
        _t('b', after: ['a'], run: const TaskQueued()),
        _t('c', run: const TaskDraft()),
      ]);
      expect([for (final t in tasksToStart(g)) t.id], ['a']);
      g = g.copyWith(
        tasks: [
          g.tasks[0].copyWith(run: const TaskDone('s1')),
          g.tasks[1],
          g.tasks[2],
        ],
      );
      expect([for (final t in tasksToStart(g)) t.id], ['b']);
      final failed = g.copyWith(
        tasks: [
          g.tasks[0].copyWith(run: const TaskFailed('x')),
          g.tasks[1],
          g.tasks[2],
        ],
      );
      expect(tasksToStart(failed), isEmpty);
      expect(taskBlocked(failed, failed.tasks[1]), isTrue);
      expect(tasksToStart(g.copyWith(stage: GoalStage.cancelled)), isEmpty);
    });

    test('loops and missing tasks are found', () {
      expect(
        dependencyProblem([
          _t('a'),
          _t('b', after: ['a']),
        ]),
        isNull,
      );
      expect(
        dependencyProblem([
          _t('a', after: ['c']),
          _t('b', after: ['a']),
          _t('c', after: ['b']),
        ]),
        contains('loop'),
      );
      expect(
        dependencyProblem([
          _t('a', after: ['z']),
        ]),
        contains("isn't there"),
      );
      expect(
        dependencyProblem([
          _t('a', after: ['a']),
        ]),
        contains('itself'),
      );
    });

    test('a start the app quit during keeps its session id; recovered by whether that session exists', () {
      final goal = _g([
        _t('a', run: const TaskStarting('s1')),
        _t('b', run: const TaskStarted('s2')),
        _t('c', run: const TaskStopping('s3')),
      ], stage: GoalStage.splitting);
      final back = PlanGoal.fromJson(jsonDecode(jsonEncode(goal.toJson())))!;
      expect(back.stage, GoalStage.draft);
      expect((back.tasks[0].run as TaskStarting).sessionId, 's1');
      expect((back.tasks[1].run as TaskStarted).sessionId, 's2');
      expect((back.tasks[2].run as TaskStopping).sessionId, 's3');
      expect(back.tasks[1].lead, _fallback);
      bool yes(String _) => true;
      bool no(String _) => false;
      expect(recoverTask(const TaskStarting('s1'), exists: yes, cancelled: false), isA<TaskStarted>());
      expect(recoverTask(const TaskStarting('s1'), exists: no, cancelled: false), isA<TaskFailed>());
      expect((recoverTask(const TaskStarting('s1'), exists: yes, cancelled: true) as TaskCancelled).sessionId, 's1');
      expect((recoverTask(const TaskStopping('s3'), exists: no, cancelled: true) as TaskCancelled).sessionId, isNull);
    });
  });

  group('race rules', () {
    test('the race follows its runners; Compare now and Keep move it on', () {
      BoardRace race(List<RunnerRun> runs, {RaceStage stage = const RaceRunning()}) => BoardRace(
        id: 'r',
        projectId: 'p1',
        prompt: 'x',
        createdAt: DateTime(2026),
        stage: stage,
        runners: [for (final r in runs) RaceRunner(lead: _fallback, run: r)],
      );
      expect(settleRace(race([const RunnerStarting('x'), const RunnerRunning('a')])), isA<RaceStarting>());
      expect(settleRace(race([const RunnerQueued('x'), const RunnerRunning('a')])), isA<RaceStarting>());
      expect(settleRace(race([const RunnerRunning('a'), RunnerDone('b', DateTime(2026))])), isA<RaceRunning>());
      expect(settleRace(race([const RunnerFailed('x'), RunnerDone('b', DateTime(2026))])), isA<RaceComparing>());
      expect(settleRace(race([const RunnerRunning('a')], stage: const RaceComparing())), isA<RaceComparing>());
      expect(settleRace(race([const RunnerRunning('a')], stage: const RaceKept('a'))), isA<RaceKept>());
      // The keep and its winner round-trip with the stage.
      final keeping = race([RunnerDone('a', DateTime(2026))], stage: const RaceKeeping('a', KeepStep.removingLosers));
      final back = BoardRace.fromJson(jsonDecode(jsonEncode(keeping.toJson())))!;
      expect(back.stage, isA<RaceKeeping>());
      expect(((back.stage as RaceKeeping).winner, (back.stage as RaceKeeping).step), ('a', KeepStep.removingLosers));
    });
  });

  group('notifiers', () {
    late AppDatabase db;
    late Preferences prefs;
    late ProviderContainer c;
    late _Planner planner;
    late _Starter starter;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      prefs = await Preferences.load(db);
      prefs['code.projects'] = '[{"id":"p1","name":"Shop","path":"/tmp/shop"}]';
      prefs['code.lead'] = jsonEncode({'harness': 'alpha', 'models': <String, Object?>{}});
      planner = _Planner();
      starter = _Starter();
      c = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          boardPlannerProvider.overrideWithValue(planner),
          boardStarterProvider.overrideWithValue(starter),
          plannerLeadsProvider.overrideWithValue(_leads),
        ],
      );
    });

    tearDown(() async {
      c.dispose();
      await db.close();
    });

    const reply =
        '{"tasks":[{"title":"API","brief":"b","harness":"beta"},{"title":"UI","after":[1],"harness":"alpha","model":"a1"},'
        '{"title":"Docs","harness":"alpha"}]}';

    test('split → delegate all: independent tasks start at once, the dependent one after its task is done', () async {
      final plans = c.read(boardPlansProvider.notifier);
      final id = plans.add(projectId: 'p1', planner: (harness: 'beta', model: ''));
      plans.setText(id, 'Ship billing v2');
      planner
        ..reply = reply
        ..gate = Completer();
      final split = plans.split(id);
      expect(plans.goal(id)!.stage, GoalStage.splitting);
      // A second Split while one runs does nothing.
      await plans.split(id);
      expect(planner.asked, hasLength(1));
      planner.gate!.complete();
      await split;
      final goal = plans.goal(id)!;
      expect(goal.stage, GoalStage.ready);
      expect([for (final t in goal.tasks) t.title], ['API', 'UI', 'Docs']);
      expect(planner.asked.single.$1, (harness: 'beta', model: ''));

      expect(plans.delegate(id), isNull);
      await pumpEventQueue();
      expect([for (final s in starter.started) s.prompt.split('\n').first], ['API', 'Docs']);
      expect(starter.started.first.lead, (harness: 'beta', model: ''));
      expect(starter.started.every((s) => s.worktree && s.mode == AgentMode.autoEdit), isTrue);
      // One start at a time: worktrees aren't made on one repository at once.
      expect(starter.overlap, 1);
      expect(plans.goal(id)!.stage, GoalStage.running);
      // The API task's session finished: UI starts on its branch's work, told so.
      starter.handoffs['s-1'] = 'api-work';
      plans.observe({'s-1': SessionOutcome.done});
      await pumpEventQueue();
      expect(starter.started.last.prompt, startsWith('UI'));
      expect(starter.started.last.prompt, contains('holds the work of "API"'));
      expect(starter.started.last.from, 'api-work');
      plans.observe({'s-2': SessionOutcome.done, 's-3': SessionOutcome.done});
      expect(plans.goal(id)!.stage, GoalStage.done);
      expect(jsonDecode(prefs[BoardPlans.key]!), hasLength(1));
    });

    test('after a restart a goal settles, and queued tasks whose tasks finished meanwhile start', () async {
      final goal = PlanGoal(
        id: 'g',
        projectId: 'p1',
        planner: _fallback,
        createdAt: DateTime(2026),
        text: 'x',
        stage: GoalStage.running,
        tasks: [
          _t('a', run: const TaskStarting('s-lost')),
          _t('b', run: const TaskDone('s-0')),
          _t('c', after: ['b'], run: const TaskQueued()),
        ],
      );
      prefs[BoardPlans.key] = jsonEncode([goal.toJson()]);
      c.dispose();
      c = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          boardPlannerProvider.overrideWithValue(planner),
          boardStarterProvider.overrideWithValue(starter),
          plannerLeadsProvider.overrideWithValue(_leads),
        ],
      );
      final plans = c.read(boardPlansProvider.notifier);
      // The start the app quit during never saved its session, so it came back failed; c had been waiting on b and
      // starts now.
      expect(plans.goal('g')!.tasks[0].run, isA<TaskFailed>());
      await pumpEventQueue();
      expect(starter.started.single.prompt, startsWith('Task c'));
      expect(plans.goal('g')!.stage, GoalStage.running);
      // Retry runs the failed one again.
      plans.retry('g', 'a');
      await pumpEventQueue();
      expect(starter.started.last.prompt, startsWith('Task a'));
      expect(plans.goal('g')!.tasks[0].run, isA<TaskStarted>());
    });

    test('Retry after a failed start unblocks the tasks waiting on it', () async {
      final plans = c.read(boardPlansProvider.notifier);
      final id = plans.add(projectId: 'p1', planner: _fallback);
      plans.setText(id, 'x');
      planner.reply = reply;
      await plans.split(id);
      final ui = plans.goal(id)!.tasks[1];
      starter.fail.add('API');
      plans.delegate(id, taskId: ui.id);
      await pumpEventQueue();
      expect(plans.goal(id)!.stage, GoalStage.failed);
      starter.fail.clear();
      plans.retry(id, plans.goal(id)!.tasks[0].id);
      await pumpEventQueue();
      expect(starter.started.single.prompt, startsWith('API'));
      // The failed start used s-1; the retry is a new session.
      expect(starter.started.single.id, 's-2');
      plans.observe({'s-2': SessionOutcome.done});
      await pumpEventQueue();
      expect(starter.started.last.prompt, startsWith('UI'));
    });

    test('removing a goal mid-split stops its planner', () async {
      final plans = c.read(boardPlansProvider.notifier);
      final id = plans.add(projectId: 'p1', planner: _fallback);
      plans.setText(id, 'x');
      planner
        ..reply = reply
        ..gate = Completer();
      final split = plans.split(id);
      expect(plans.busy(id), isTrue);
      plans.remove(id);
      await pumpEventQueue();
      expect(planner.cancelled, isTrue);
      planner.gate!.complete();
      await split;
      expect(c.read(boardPlansProvider), isEmpty);
    });

    test('loops are refused before anything starts; Cancel leaves started sessions unless asked', () async {
      final plans = c.read(boardPlansProvider.notifier);
      final id = plans.add(projectId: 'p1', planner: _fallback);
      plans.setText(id, 'x');
      planner.reply = reply;
      await plans.split(id);
      final [api, ui, docs] = plans.goal(id)!.tasks;
      expect(plans.setAfter(id, api.id, [ui.id]), isFalse);
      expect(plans.goal(id)!.task(api.id)!.after, isEmpty);
      plans.delegate(id, taskId: docs.id);
      await pumpEventQueue();
      plans.cancel(id);
      final goal = plans.goal(id)!;
      expect(goal.stage, GoalStage.cancelled);
      expect([for (final t in goal.tasks) t.run.runtimeType], [TaskCancelled, TaskCancelled, TaskStarted]);
      expect(starter.stopped, isEmpty);
      final id2 = plans.add(projectId: 'p1', planner: _fallback);
      plans.setText(id2, 'y');
      await plans.split(id2);
      plans.delegate(id2);
      await pumpEventQueue();
      // Stop reaches every started session, whether or not its view was ever opened.
      plans.cancel(id2, started: StartedChoice.stop);
      await pumpEventQueue();
      expect(starter.stopped, ['s-2', 's-3']);
    });

    test('a race starts every runner in a worktree, records when each finished, and keeps one', () async {
      final races = c.read(boardRacesProvider.notifier);
      final project = c.read(codeProjectsProvider).single;
      final id = races.start(
        project: project,
        prompt: 'Make it faster',
        leads: const [(harness: 'alpha', model: 'a1'), (harness: 'beta', model: '')],
      );
      expect(races.race(id)!.stage, isA<RaceStarting>());
      await pumpEventQueue();
      expect(races.race(id)!.stage, isA<RaceRunning>());
      expect(starter.started.every((s) => s.worktree && s.prompt == 'Make it faster'), isTrue);
      races.observe({'s-1': SessionOutcome.done}, now: DateTime(2030));
      expect(races.race(id)!.runners[0].run, isA<RunnerDone>());
      expect(races.race(id)!.stage, isA<RaceRunning>());
      races.observe({'s-2': SessionOutcome.failed});
      expect(races.race(id)!.stage, isA<RaceComparing>());
      expect(races.keepBlocked(id), isNull);
      // Only a finished runner can be kept.
      expect(races.beginKeep(id, 's-2'), contains("isn't finished"));
      expect(races.beginKeep(id, 's-1'), isNull);
      expect(races.race(id)!.stage, isA<RaceKeeping>());
      expect(races.beginKeep(id, 's-1'), contains('already'));
      await races.settleKeep(id, merged: true);
      final kept = races.race(id)!;
      expect(winnerOf(kept.stage), 's-1');
      expect(kept.stage, isA<RaceKept>());
      expect(kept.runners[1].run, isA<RunnerDiscarded>());
      // The loser's worktree goes (its branch stays: BoardStarter.discard keeps it).
      expect(starter.discarded, ['s-2']);
      expect(winnerOf(BoardRace.fromJson((jsonDecode(prefs[BoardRaces.key]!) as List<Object?>)[0])!.stage), 's-1');
    });

    test('a race restored mid-start settles instead of staying Starting', () {
      final race = BoardRace(
        id: 'r',
        projectId: 'p1',
        prompt: 'x',
        createdAt: DateTime(2026),
        stage: const RaceRunning(),
        runners: [
          RaceRunner(lead: _fallback, run: const RunnerStarting('s-lost')),
          RaceRunner(lead: _fallback, run: RunnerDone('s', DateTime(2026))),
        ],
      );
      prefs[BoardRaces.key] = jsonEncode([race.toJson()]);
      c.dispose();
      c = ProviderContainer(overrides: [preferencesProvider.overrideWithValue(prefs)]);
      expect(c.read(boardRacesProvider).single.stage, isA<RaceComparing>());
    });

    ProviderContainer restart() {
      c.dispose();
      return c = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          boardPlannerProvider.overrideWithValue(planner),
          boardStarterProvider.overrideWithValue(starter),
          plannerLeadsProvider.overrideWithValue(_leads),
        ],
      );
    }

    test('a quit while a task or runner starts finds its session again by id; nothing starts twice', () async {
      final goal = PlanGoal(
        id: 'g',
        projectId: 'p1',
        planner: _fallback,
        createdAt: DateTime(2026),
        text: 'x',
        stage: GoalStage.running,
        tasks: [
          _t('a', run: const TaskStarting('s-made')),
          _t('b', after: ['a'], run: const TaskQueued()),
        ],
      );
      final race = BoardRace(
        id: 'r',
        projectId: 'p1',
        prompt: 'x',
        createdAt: DateTime(2026),
        stage: const RaceStarting(),
        runners: [
          RaceRunner(lead: _fallback, run: const RunnerStarting('s-ran')),
          RaceRunner(lead: _fallback, run: const RunnerQueued('s-next')),
        ],
      );
      prefs[BoardPlans.key] = jsonEncode([goal.toJson()]);
      prefs[BoardRaces.key] = jsonEncode([race.toJson()]);
      // Both starts had saved their sessions before the quit.
      starter.existing.addAll({'s-made', 's-ran'});
      restart();
      expect(c.read(boardPlansProvider).single.tasks[0].run, isA<TaskStarted>());
      expect((c.read(boardRacesProvider).single.runners[0].run as RunnerRunning).sessionId, 's-ran');
      await pumpEventQueue();
      // Only the runner still queued started (with the id it was given); b waits for a to finish.
      expect([for (final s in starter.started) s.id], ['s-next']);
    });

    test('a Keep lives in the race: resumed after a quit mid-merge (landed or not)', () async {
      BoardRace keeping(String id) => BoardRace(
        id: id,
        projectId: 'p1',
        prompt: 'x',
        createdAt: DateTime(2026),
        stage: const RaceKeeping('w', KeepStep.merging),
        runners: [
          RaceRunner(lead: _fallback, run: RunnerDone('w', DateTime(2026))),
          RaceRunner(lead: _fallback, run: RunnerDone('l-$id', DateTime(2026))),
        ],
      );
      prefs[BoardRaces.key] = jsonEncode([keeping('a').toJson()]);
      starter.landedSessions.add('w');
      restart();
      c.read(boardRacesProvider);
      await pumpEventQueue();
      // The winner's work was on its base: the Keep finished, the loser's worktree removed.
      expect(c.read(boardRacesProvider).single.stage, isA<RaceKept>());
      expect(starter.discarded, ['l-a']);
      starter.landedSessions.clear();
      prefs[BoardRaces.key] = jsonEncode([keeping('b').toJson()]);
      restart();
      c.read(boardRacesProvider);
      await pumpEventQueue();
      // Nothing merged: back to comparing, the loser untouched.
      expect(c.read(boardRacesProvider).single.stage, isA<RaceComparing>());
      expect(starter.discarded, ['l-a']);
    });
  });

  test("the planner's read-only claim is made only where it holds", () {
    expect(PlannerCli.claude.guard, contains("settings, hooks and MCP servers aren't loaded"));
    for (final cli in [PlannerCli.codex, PlannerCli.opencode, PlannerCli.gemini]) {
      expect(cli.guard, contains('still load'));
    }
  });
}
