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
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/drivers/driver_events.dart';
import 'package:every_ai/features/code/git/git_models.dart';
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

/// A starter that records each start and returns `s-<n>`; [fail] names prompts that fail to start; [gate] holds
/// starts; [handoffs] are the commits of sessions' work (none: it ran in the project folder).
final class _Starter implements BoardStarter {
  final started = <({String prompt, LeadPick lead, bool worktree, AgentMode mode, String? from})>[];
  final fail = <String>{};
  Completer<void>? gate;
  final handoffs = <String, String>{};
  final stopped = <String>[];
  final discarded = <String>[];

  /// Starts that ran at the same time as another, at most.
  var overlap = 0;
  var _running = 0;

  @override
  Future<String> start({
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
      started.add((prompt: prompt, lead: lead, worktree: worktree, mode: mode, from: fromCommit));
      return 's-${started.length}';
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
    test('takes the last object with a tasks list, skipping other objects; long briefs are cut', () {
      final long = 'x' * 5000;
      final split = _parse(
        'I read {"name":"shop","version":"1.0"} and "quotes" here.\n'
        '{"tasks":[{"title":"A","brief":"$long"},{"title":"B"}]}',
      );
      final tasks = (split as SplitTasks).tasks;
      expect([for (final t in tasks) t.title], ['A', 'B']);
      expect(tasks.first.brief.length, maxBriefChars);
    });

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

    test('refuses replies without tasks, with too few or too many, bad dependencies or a loop', () {
      String why(String reply) => (_parse(reply) as SplitRefused).why;
      expect(why('Sorry, I cannot help.'), contains('no tasks'));
      expect(why('{"tasks":[{"title":"Only one"}]}'), contains('one task'));
      expect(
        why(
          jsonEncode({
            'tasks': List.generate(9, (i) => {'title': 'T$i'}),
          }),
        ),
        contains('more than 8'),
      );
      expect(why('{"tasks":[{"title":"A","after":[2]},{"title":"B","after":[1]}]}'), contains('loop'));
      expect(why('{"tasks":[{"title":"A","after":[1]},{"title":"B"}]}'), contains('itself'));
      expect(why('{"tasks":[{"title":"A","after":[5]},{"title":"B"}]}'), contains("isn't there"));
      expect(why('{"tasks":[{"title":""},{"title":"B"}]}'), contains('no title'));
    });

    test('the prompt names every lead and its models, and the shape to reply in', () {
      final prompt = planSplitPrompt('Ship billing v2', project: 'shop', leads: _leads);
      expect(prompt, contains('"alpha" (Alpha), models: "a1", "a2"'));
      expect(prompt, contains('"beta" (Beta)'));
      expect(prompt, contains('{"tasks":[{"title"'));
      expect(prompt, endsWith('Ship billing v2'));
    });

    test("each CLI plans headless and read-only; Claude's JSON reply is unwrapped", () {
      // No MCP servers and only the user's own settings (a repository's hooks don't run).
      expect(plannerArgs(PlannerCli.claude, model: 'anthropic/claude-opus-5.5', prompt: 'P'), [
        '-p',
        'P',
        '--output-format',
        'json',
        '--permission-mode',
        'plan',
        '--strict-mcp-config',
        '--setting-sources',
        'user',
        '--no-session-persistence',
        '--model',
        'claude-opus-5-5',
      ]);
      expect(plannerArgs(PlannerCli.codex, model: '', prompt: 'P', lastMessage: '/t/r'), [
        'exec',
        '--skip-git-repo-check',
        '--sandbox',
        'read-only',
        '-c',
        'mcp_servers={}',
        '--output-last-message',
        '/t/r',
        '--',
        'P',
      ]);
      // OpenCode's plan agent, not its build agent.
      expect(plannerArgs(PlannerCli.opencode, model: 'x/y', prompt: 'P'), [
        'run',
        '--agent',
        'plan',
        '-m',
        'x/y',
        '--',
        'P',
      ]);
      expect(plannerArgs(PlannerCli.gemini, model: '', prompt: 'P'), [
        '-p',
        'P',
        '--approval-mode',
        'plan',
        '--allowed-mcp-server-names',
        'none',
      ]);
      expect(plannerReplyText(PlannerCli.claude, '{"type":"result","result":"{\\"tasks\\":[]}"}'), '{"tasks":[]}');
      expect(plannerReplyText(PlannerCli.gemini, 'plain'), 'plain');
      expect(
        () => plannerReplyText(PlannerCli.claude, '{"is_error":true,"result":"Not logged in"}'),
        throwsA(isA<HarnessError>()),
      );
      expect(PlannerCli.of('acp:kiro'), isNull);
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

    test("a dependent task's prompt says whose work its branch holds, what to merge first and what isn't there", () {
      final g = _g([
        _t('a', run: TaskDone('s1', at: DateTime(2026, 1, 1, 9))),
        _t('b', run: TaskDone('s2', at: DateTime(2026, 1, 1, 10))),
        _t('c', run: const TaskDone('s3')),
        _t('d', after: ['a', 'b', 'c']),
      ]);
      // The one that finished last first; unknown times last.
      expect([for (final t in depsByFinish(g, g.tasks[3])) t.id], ['b', 'a', 'c']);
      final prompt = planTaskPrompt(
        g,
        g.tasks[3],
        handoff: (
          base: (title: 'Task b', commit: 'bbb'),
          merges: [(title: 'Task a', commit: 'aaa')],
          inPlace: ['Task c'],
        ),
      );
      expect(prompt, contains('Your branch already holds the work of "Task b"'));
      expect(prompt, contains('`git merge --no-edit aaa` ("Task a")'));
      expect(prompt, contains('"Task c" ran in the project folder itself'));
      expect(planTaskPrompt(g, g.tasks[0]), isNot(contains('merge')));
    });

    test('what a tracked session counts as: done only when done with nothing under it working', () {
      final info = CodeSessionInfo(
        id: 's',
        projectId: 'p1',
        title: 's',
        conversationId: 'c',
        model: '',
        mode: AgentMode.ask,
        workingDir: '/w',
        createdAt: DateTime(2026),
      );
      expect(sessionOutcome(info: null, own: null, childrenWorking: false), SessionOutcome.gone);
      expect(sessionOutcome(info: info, own: SessionStatus.done, childrenWorking: false), SessionOutcome.done);
      expect(sessionOutcome(info: info, own: SessionStatus.done, childrenWorking: true), SessionOutcome.running);
      // Idle reads before a first turn: not done.
      expect(sessionOutcome(info: info, own: SessionStatus.idle, childrenWorking: false), SessionOutcome.running);
      expect(sessionOutcome(info: info, own: SessionStatus.failed, childrenWorking: false), SessionOutcome.failed);
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

    test('the goal follows its tasks', () {
      expect(settleGoal(_g([_t('a'), _t('b')])), GoalStage.ready);
      expect(settleGoal(_g([_t('a', run: const TaskStarted('s')), _t('b')])), GoalStage.running);
      expect(settleGoal(_g([_t('a', run: const TaskDone('s')), _t('b', run: const TaskDone('t'))])), GoalStage.done);
      expect(
        settleGoal(
          _g([
            _t('a', run: const TaskFailed('x')),
            _t('b', after: ['a'], run: const TaskQueued()),
          ]),
        ),
        GoalStage.failed,
      );
      expect(settleGoal(_g([_t('a', run: const TaskDone('s')), _t('b', run: const TaskCancelled())])), GoalStage.done);
      // A part delegated and done, the rest still drafts: ready for more.
      expect(settleGoal(_g([_t('a', run: const TaskDone('s')), _t('b')])), GoalStage.ready);
      expect(settleGoal(_g([_t('a')], stage: GoalStage.draft)), GoalStage.draft);
      expect(settleGoal(_g([_t('a', run: const TaskStarted('s'))], stage: GoalStage.cancelled)), GoalStage.cancelled);
    });

    test('reordering and removing keep the dependencies right', () {
      final tasks = [
        _t('a'),
        _t('b', after: ['a']),
        _t('c', after: ['a', 'b']),
      ];
      expect([for (final t in reorderTasks(tasks, 2, 0)) t.id], ['c', 'a', 'b']);
      expect([for (final t in reorderTasks(tasks, 0, 3)) t.id], ['b', 'c', 'a']);
      final left = withoutTask(tasks, 'a');
      expect([for (final t in left) '${t.id}<-${t.after.join(',')}'], ['b<-', 'c<-b']);
    });

    test('a start the app quit during comes back failed, a split comes back a draft', () {
      final goal = _g([
        _t('a', run: const TaskStarting()),
        _t('b', run: const TaskStarted('s2')),
      ], stage: GoalStage.splitting);
      final back = PlanGoal.fromJson(jsonDecode(jsonEncode(goal.toJson())))!;
      expect(back.stage, GoalStage.draft);
      expect(back.tasks[0].run, isA<TaskFailed>());
      expect((back.tasks[1].run as TaskStarted).sessionId, 's2');
      expect(back.tasks[1].lead, _fallback);
    });
  });

  group('race rules', () {
    CodeSessionInfo s(String id, String harness, String model, {int day = 1, String? parent}) => CodeSessionInfo(
      id: id,
      projectId: 'p1',
      title: id,
      conversationId: 'c-$id',
      model: model,
      mode: AgentMode.ask,
      workingDir: '/w',
      createdAt: DateTime(2026, 11, day),
      harness: harness,
      parentId: parent,
    );

    test('the default runners are the two leads used most, newest first on a tie; the fallback fills in', () {
      final sessions = [
        s('1', 'alpha', 'a1'),
        s('2', 'alpha', 'a1', day: 2),
        s('3', 'beta', '', day: 3),
        s('4', 'gamma', 'g', day: 4),
        s('5', 'gamma', 'g', day: 5, parent: '4'),
        s('6', 'off', 'o', day: 6),
        s('7', 'off', 'o', day: 7),
        s('8', 'off', 'o', day: 8),
      ];
      expect(defaultRunners(sessions, usable: (h) => h != 'off', fallback: const []), [
        (harness: 'alpha', model: 'a1'),
        (harness: 'gamma', model: 'g'),
      ]);
      expect(
        defaultRunners(
          const [],
          usable: (h) => true,
          fallback: const [(harness: 'x', model: ''), (harness: 'y', model: '')],
        ),
        [(harness: 'x', model: ''), (harness: 'y', model: '')],
      );
    });

    test('the race follows its runners; Compare now and Keep move it on', () {
      BoardRace race(List<RunnerRun> runs, {RaceStage stage = RaceStage.running}) => BoardRace(
        id: 'r',
        projectId: 'p1',
        prompt: 'x',
        createdAt: DateTime(2026),
        stage: stage,
        runners: [for (final r in runs) RaceRunner(lead: _fallback, run: r)],
      );
      expect(settleRace(race([const RunnerStarting(), const RunnerRunning('a')])), RaceStage.starting);
      expect(settleRace(race([const RunnerRunning('a'), RunnerDone('b', DateTime(2026))])), RaceStage.running);
      expect(settleRace(race([const RunnerFailed('x'), RunnerDone('b', DateTime(2026))])), RaceStage.comparing);
      expect(settleRace(race([const RunnerRunning('a')], stage: RaceStage.comparing)), RaceStage.comparing);
      expect(settleRace(race([const RunnerRunning('a')], stage: RaceStage.kept)), RaceStage.kept);
    });

    test("a runner's numbers: its diff, its last test command and its wall time", () {
      FileDiff file(String path, int added, int removed) => FileDiff(
        path: path,
        header: const [],
        hunks: [
          DiffHunk(
            header: '@@',
            oldStart: 1,
            newStart: 1,
            lines: [for (var i = 0; i < added; i++) '+x', for (var i = 0; i < removed; i++) '-y'],
          ),
        ],
      );
      ToolStep step(String id, String command, {bool ok = true}) {
        final call = actionEvent(id: id, toolName: 'Bash', kind: 'TerminalAction', args: {'command': command});
        return ToolStep(call, resultEvent(id: 'r$id', actionId: id, toolName: 'Bash', text: '', isError: !ok));
      }

      final t = Transcript(
        items: [
          StepItem(step('1', 'flutter test', ok: false)),
          StepItem(step('2', 'ls')),
          ExploreGroup('g', [step('3', 'cd app && npm run test')]),
        ],
      );
      final stats = runnerStats(
        files: [file('a.dart', 3, 1), file('b.dart', 2, 0)],
        transcript: t,
        startedAt: DateTime(2026, 1, 1, 10),
        run: RunnerDone('s', DateTime(2026, 1, 1, 10, 12)),
      );
      expect((stats.files, stats.added, stats.removed, stats.tests), (2, 5, 1, RunnerTests.passed));
      expect(wallText(stats.wall!), '12 min');
      expect(testsOf(Transcript(items: [StepItem(step('9', 'pytest -q', ok: false))])), RunnerTests.failed);
      expect(testsOf(Transcript(items: [StepItem(step('9', 'git status'))])), RunnerTests.notRun);
      expect(wallText(const Duration(minutes: 72)), '1 h 12 min');
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
          _t('a', run: const TaskStarting()),
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
      // The start the app quit during came back failed; c had been waiting on b and starts now.
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

    test('the goal picks the mode its tasks start in', () async {
      final plans = c.read(boardPlansProvider.notifier);
      final id = plans.add(projectId: 'p1', planner: _fallback);
      plans
        ..setText(id, 'x')
        ..setMode(id, AgentMode.ask);
      planner.reply = reply;
      await plans.split(id);
      plans.delegate(id);
      await pumpEventQueue();
      expect(starter.started.every((s) => s.mode == AgentMode.ask), isTrue);
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
      plans.observe({'s-1': SessionOutcome.done});
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

    test('a bad reply or an error leaves a draft with why; an old split\'s reply is dropped', () async {
      final plans = c.read(boardPlansProvider.notifier);
      final id = plans.add(projectId: 'p1', planner: _fallback);
      plans.setText(id, 'Do it');
      planner.reply = 'no idea';
      await plans.split(id);
      expect(plans.goal(id)!.stage, GoalStage.draft);
      expect(plans.goal(id)!.error, contains('no tasks'));
      planner
        ..reply = ''
        ..error = const HarnessError('Not signed in');
      await plans.split(id);
      expect(plans.goal(id)!.error, 'Not signed in');
      // Removed while splitting: the reply lands nowhere.
      planner
        ..error = null
        ..reply = reply
        ..gate = Completer();
      final split = plans.split(id);
      plans.remove(id);
      planner.gate!.complete();
      await split;
      expect(c.read(boardPlansProvider), isEmpty);
    });

    test('delegating one task queues the drafts it waits on; a failed start or session blocks what waits', () async {
      final plans = c.read(boardPlansProvider.notifier);
      final id = plans.add(projectId: 'p1', planner: _fallback);
      plans.setText(id, 'x');
      planner.reply = reply;
      await plans.split(id);
      final ui = plans.goal(id)!.tasks[1];
      starter.fail.add('API');
      plans.delegate(id, taskId: ui.id);
      await pumpEventQueue();
      final goal = plans.goal(id)!;
      expect(goal.tasks[0].run, isA<TaskFailed>());
      expect(goal.tasks[1].run, isA<TaskQueued>());
      expect(taskBlocked(goal, goal.tasks[1]), isTrue);
      // Docs wasn't asked for.
      expect(goal.tasks[2].run, isA<TaskDraft>());
      expect(goal.stage, GoalStage.failed);
      expect(starter.started, isEmpty);
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

    test('Cancel with Stop while a task is starting stops its session once it exists', () async {
      final plans = c.read(boardPlansProvider.notifier);
      final id = plans.add(projectId: 'p1', planner: _fallback);
      plans.setText(id, 'x');
      planner.reply = reply;
      await plans.split(id);
      starter.gate = Completer();
      plans.delegate(id);
      await pumpEventQueue();
      expect(plans.goal(id)!.tasks[0].run, isA<TaskStarting>());
      plans.cancel(id, started: StartedChoice.stop);
      starter.gate!.complete();
      await pumpEventQueue();
      expect(plans.goal(id)!.tasks[0].run, isA<TaskCancelled>());
      expect(starter.stopped, ['s-1']);
      // Nothing more started after the cancel.
      expect(starter.started, hasLength(1));
    });

    test('the plans follow their sessions app-wide, with the Board closed', () async {
      final info = CodeSessionInfo(
        id: 's-1',
        projectId: 'p1',
        title: 'API',
        conversationId: 'c',
        model: '',
        mode: AgentMode.autoEdit,
        workingDir: 'demo://p1',
        createdAt: DateTime(2026),
      );
      final goal = PlanGoal(
        id: 'g',
        projectId: 'p1',
        planner: _fallback,
        createdAt: DateTime(2026),
        text: 'x',
        stage: GoalStage.running,
        tasks: [
          _t('a', run: const TaskStarted('s-1')),
          _t('b', after: ['a'], run: const TaskQueued()),
        ],
      );
      prefs[BoardPlans.key] = jsonEncode([goal.toJson()]);
      prefs['code.sessions'] = jsonEncode([info.toJson()]);
      var statuses = <String, SessionStatus>{'s-1': SessionStatus.running};
      c.dispose();
      c = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          boardPlannerProvider.overrideWithValue(planner),
          boardStarterProvider.overrideWithValue(starter),
          plannerLeadsProvider.overrideWithValue(_leads),
          codeStatusesProvider.overrideWithBuild((ref, _) => statuses),
        ],
      );
      c.listen(boardPlanWatchProvider, (_, _) {});
      await pumpEventQueue();
      expect(starter.started, isEmpty);
      statuses = {'s-1': SessionStatus.done};
      c.invalidate(codeStatusesProvider);
      c.read(boardPlanWatchProvider);
      await pumpEventQueue();
      expect(c.read(boardPlansProvider).single.tasks[0].run, isA<TaskDone>());
      expect(starter.started.single.prompt, startsWith('Task b'));
    });

    test('a race starts every runner in a worktree, records when each finished, and keeps one', () async {
      final races = c.read(boardRacesProvider.notifier);
      final project = c.read(codeProjectsProvider).single;
      final id = races.start(
        project: project,
        prompt: 'Make it faster',
        leads: const [(harness: 'alpha', model: 'a1'), (harness: 'beta', model: '')],
      );
      expect(races.race(id)!.stage, RaceStage.starting);
      await pumpEventQueue();
      expect(races.race(id)!.stage, RaceStage.running);
      expect(starter.started.every((s) => s.worktree && s.prompt == 'Make it faster'), isTrue);
      races.observe({'s-1': SessionOutcome.done}, now: DateTime(2030));
      expect(races.race(id)!.runners[0].run, isA<RunnerDone>());
      expect(races.race(id)!.stage, RaceStage.running);
      races.observe({'s-2': SessionOutcome.failed});
      expect(races.race(id)!.stage, RaceStage.comparing);
      expect(races.keepBlocked(id), isNull);
      races.keep(id, 's-1');
      final kept = races.race(id)!;
      expect((kept.stage, kept.keptSession), (RaceStage.kept, 's-1'));
      expect(kept.runners[1].run, isA<RunnerDiscarded>());
      expect(BoardRace.fromJson((jsonDecode(prefs[BoardRaces.key]!) as List<Object?>)[0])!.keptSession, 's-1');
    });

    test('Keep waits for runners still starting; Cancel with Stop removes runners, even ones starting', () async {
      final races = c.read(boardRacesProvider.notifier);
      final project = c.read(codeProjectsProvider).single;
      starter.gate = Completer();
      final id = races.start(
        project: project,
        prompt: 'Go',
        leads: const [(harness: 'alpha', model: 'a1'), (harness: 'beta', model: '')],
      );
      await pumpEventQueue();
      expect(races.keepBlocked(id), contains('still starting'));
      races.cancel(id, started: StartedChoice.stop);
      starter.gate!.complete();
      await pumpEventQueue();
      // The first runner started after the cancel: stopped and removed; the second never started.
      expect(starter.stopped, ['s-1']);
      expect(starter.discarded, ['s-1']);
      expect(starter.started, hasLength(1));
      expect(races.race(id)!.runners.every((r) => r.run is RunnerDiscarded), isTrue);
    });

    test('a race restored mid-start settles instead of staying Starting', () {
      final race = BoardRace(
        id: 'r',
        projectId: 'p1',
        prompt: 'x',
        createdAt: DateTime(2026),
        stage: RaceStage.running,
        runners: [
          RaceRunner(lead: _fallback, run: const RunnerStarting()),
          RaceRunner(lead: _fallback, run: RunnerDone('s', DateTime(2026))),
        ],
      );
      prefs[BoardRaces.key] = jsonEncode([race.toJson()]);
      c.dispose();
      c = ProviderContainer(overrides: [preferencesProvider.overrideWithValue(prefs)]);
      expect(c.read(boardRacesProvider).single.stage, RaceStage.comparing);
    });
  });
}
