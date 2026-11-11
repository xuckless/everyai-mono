import 'dart:convert';

import 'package:drift/native.dart';
import 'package:every_ai/app/shell.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/ui/kit.dart' show KitButton;
import 'package:every_ai/features/code/board/board_plan.dart';
import 'package:every_ai/features/code/board/board_plan_providers.dart';
import 'package:every_ai/features/code/board/board_plan_view.dart';
import 'package:every_ai/features/code/board/board_planner.dart';
import 'package:every_ai/features/code/board/board_providers.dart' show BoardMarks;
import 'package:every_ai/features/code/board/board_race.dart';
import 'package:every_ai/features/code/board/board_screen.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../../layout/layout_host.dart';

// The Plan lane on the Board: a goal written, split by a (fake) planner, edited and delegated, with the dependent
// task starting once its task's session is done; and a race compared and one runner kept.

const _leads = <PlannerLead>[
  (id: 'alpha', label: 'Alpha', models: ['a1']),
  (id: 'beta', label: 'Beta', models: []),
];

CodeSessionInfo _s(String id, {String harness = 'alpha', String model = ''}) => CodeSessionInfo(
  id: id,
  projectId: 'p1',
  title: 'Session $id',
  conversationId: 'c-$id',
  model: model,
  mode: AgentMode.autoEdit,
  // Demo sessions: the status poller leaves them alone.
  workingDir: 'demo://p1',
  createdAt: DateTime(2026, 11, 11),
  harness: harness,
);

final class _Planner implements BoardPlanner {
  _Planner(this.reply);
  final String reply;
  final asked = <LeadPick>[];

  @override
  String? unavailable(LeadPick pick) => null;

  @override
  Future<String> ask(
    LeadPick pick,
    String prompt, {
    required CodeProject project,
    required String tag,
    Future<void>? cancel,
  }) async {
    asked.add(pick);
    return reply;
  }
}

/// Starts each session as a demo session in the list, like the real start does before it returns.
final class _Starter implements BoardStarter {
  _Starter(this.c);
  final ProviderContainer c;
  final started = <({String title, bool worktree, LeadPick lead})>[];

  @override
  Future<String> start({
    required CodeProject project,
    required String prompt,
    required LeadPick lead,
    required bool worktree,
    required AgentMode mode,
    String? fromCommit,
  }) async {
    started.add((title: prompt.split('\n').first, worktree: worktree, lead: lead));
    final id = 's-${started.length}';
    // ignore: invalid_use_of_protected_member
    c.read(codeSessionsProvider.notifier).state = [
      _s(id, harness: lead.harness, model: lead.model),
      ...c.read(codeSessionsProvider),
    ];
    return id;
  }

  @override
  Future<String?> handoff(String sessionId) async => null;

  @override
  Future<void> stop(String sessionId) async {}

  @override
  Future<void> discard(String sessionId) async {}
}

final class _Actions implements RaceActions {
  /// What happened, in order.
  final log = <String>[];

  /// Whether the merge lands.
  var merges = true;

  @override
  Future<bool> merge(BuildContext context, WidgetRef ref, CodeSessionInfo winner) async {
    log.add('merge ${winner.id}${merges ? '' : ' (not merged)'}');
    return merges;
  }

  @override
  Future<void> discard(WidgetRef ref, CodeSessionInfo loser) async => log.add('discard ${loser.id}');
}

Future<(ProviderContainer, Preferences)> _board(
  WidgetTester tester, {
  List<CodeSessionInfo> sessions = const [],
  Map<String, String> more = const {},
  List<Override> overrides = const [],
  ProviderContainer Function(List<Override>)? make,
}) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final prefs = await Preferences.load(db);
  prefs['code.projects'] = '[{"id":"p1","name":"Shop","path":"/tmp/shop"}]';
  prefs[BoardMarks.doneSinceKey] = '{}';
  prefs['code.sessions'] = jsonEncode([for (final s in sessions) s.toJson()]);
  more.forEach((k, v) => prefs[k] = v);
  final all = [
    preferencesProvider.overrideWithValue(prefs),
    plannerLeadsProvider.overrideWithValue(_leads),
    defaultLeadProvider.overrideWithValue((harness: 'alpha', model: '')),
    ...overrides,
  ];
  final c = make?.call(all) ?? ProviderContainer(overrides: all);
  c.listen(codeStatusesProvider, (_, _) {});
  // The shell keeps the plans following their sessions app-wide.
  c.listen(boardPlanWatchProvider, (_, _) {});
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: LayoutHost(
        language: DesignLanguage.material,
        child: ShellScope(sidebarVisible: true, compact: false, toggleSidebar: () {}, child: const BoardScreen()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (c, prefs);
}

Future<void> _done(WidgetTester tester, ProviderContainer c) async {
  await tester.pumpWidget(const SizedBox());
  debugDefaultTargetPlatformOverride = null;
  tester.view.reset();
  c.dispose();
}

ValueKey<String> _k(String key) => ValueKey(key);

void main() {
  testWidgets('a new goal is split, edited and delegated; the dependent task starts once its task is done', (
    tester,
  ) async {
    final planner = _Planner(
      '{"tasks":[{"title":"API","brief":"Routes.","harness":"beta"},'
      '{"title":"UI","brief":"Page.","after":[1],"harness":"alpha","model":"a1"},'
      '{"title":"Docs","brief":"Readme.","harness":"alpha"}]}',
    );
    late _Starter starter;
    final (c, prefs) = await _board(
      tester,
      make: (all) {
        late ProviderContainer c;
        c = ProviderContainer(
          overrides: [
            ...all,
            boardPlannerProvider.overrideWithValue(planner),
            boardStarterProvider.overrideWith((ref) => starter = _Starter(c)),
          ],
        );
        return c;
      },
    );
    expect(find.byKey(_k('board.column.plan')), findsOneWidget);

    await tester.tap(find.byKey(_k('board.plan.new')));
    await tester.pumpAndSettle();
    final id = c.read(boardPlansProvider).single.id;
    await tester.enterText(find.byKey(_k('board.goal.text.$id')), 'Ship billing v2');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_k('board.goal.split.$id')));
    await tester.pumpAndSettle();
    expect(planner.asked.single, (harness: 'alpha', model: ''));
    final tasks = c.read(boardPlansProvider).single.tasks;
    expect([for (final t in tasks) t.title], ['API', 'UI', 'Docs']);
    expect(find.text('Readme.'), findsOneWidget);

    // Edits: the third task gets a new title, the first works in the project folder.
    await tester.enterText(find.byKey(_k('board.task.title.${tasks[2].id}')), 'Docs page');
    await tester.tap(find.byKey(_k('board.task.worktree.${tasks[0].id}')));
    await tester.pumpAndSettle();
    expect(c.read(boardPlansProvider).single.tasks[2].title, 'Docs page');

    await tester.tap(find.byKey(_k('board.goal.delegate.$id')));
    await tester.pumpAndSettle();
    expect([for (final s in starter.started) s.title], ['API', 'Docs page']);
    expect([for (final s in starter.started) s.worktree], [false, true]);
    expect(starter.started.first.lead, (harness: 'beta', model: ''));
    // The sessions carry the goal's chip; the UI task waits.
    expect(find.byKey(_k('board.goalchip.s-1')), findsOneWidget);
    expect(find.text('Waiting on 1'), findsOneWidget);
    expect(find.text('0 of 3'), findsOneWidget);

    // The API task's session finished: UI starts on its own lead.
    // ignore: invalid_use_of_protected_member
    c.read(codeStatusesProvider.notifier).state = {'s-1': SessionStatus.done};
    await tester.pumpAndSettle();
    expect([for (final s in starter.started) s.title], ['API', 'Docs page', 'UI']);
    expect(starter.started.last.lead, (harness: 'alpha', model: 'a1'));
    expect(find.text('1 of 3'), findsOneWidget);
    expect(jsonDecode(prefs[BoardPlans.key]!), hasLength(1));
    await _done(tester, c);
  });

  testWidgets('a race compares its runners; Keep asks, merges the one kept first, then removes the others', (
    tester,
  ) async {
    final actions = _Actions();
    final race = BoardRace(
      id: 'r',
      projectId: 'p1',
      prompt: 'Make checkout faster',
      createdAt: DateTime(2026, 11, 11),
      stage: RaceStage.running,
      runners: [
        RaceRunner(lead: (harness: 'alpha', model: 'a1'), run: const RunnerRunning('w1'), startedAt: DateTime(2026)),
        RaceRunner(lead: (harness: 'beta', model: ''), run: const RunnerRunning('w2'), startedAt: DateTime(2026)),
      ],
    );
    final (c, prefs) = await _board(
      tester,
      sessions: [
        _s('w1', model: 'a1'),
        _s('w2', harness: 'beta'),
      ],
      more: {
        BoardRaces.key: jsonEncode([race.toJson()]),
      },
      overrides: [boardRaceActionsProvider.overrideWithValue(actions)],
    );
    expect(find.byKey(_k('board.race.r')), findsOneWidget);
    // Nothing finished yet: no comparing.
    final compare = find.byKey(_k('board.race.compare.r'));
    expect(tester.widget<KitButton>(compare).onPressed, isNull);

    // ignore: invalid_use_of_protected_member
    c.read(codeStatusesProvider.notifier).state = {'w1': SessionStatus.done, 'w2': SessionStatus.done};
    await tester.pumpAndSettle();
    expect(c.read(boardRacesProvider).single.stage, RaceStage.comparing);
    await tester.tap(compare);
    await tester.pumpAndSettle();
    expect(find.text('Compare'), findsWidgets);
    expect(find.byKey(_k('board.compare.0')), findsOneWidget);
    expect(find.byKey(_k('board.compare.1')), findsOneWidget);

    // A merge that doesn't land (the user said no, or the agent tidies first) removes nothing.
    actions.merges = false;
    await tester.tap(find.byKey(_k('board.compare.keep.w1')));
    await tester.pumpAndSettle();
    expect(find.text('Keep this one?'), findsOneWidget);
    expect(find.textContaining('Beta'), findsWidgets);
    expect(actions.log, isEmpty);
    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();
    expect(actions.log, ['merge w1 (not merged)']);
    expect(c.read(boardRacesProvider).single.stage, RaceStage.comparing);

    actions.merges = true;
    await tester.tap(compare);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_k('board.compare.keep.w1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();
    expect(actions.log, ['merge w1 (not merged)', 'merge w1', 'discard w2']);
    final kept = c.read(boardRacesProvider).single;
    expect((kept.stage, kept.keptSession), (RaceStage.kept, 'w1'));
    expect(prefs[BoardRaces.key], contains('"kept":"w1"'));
    await _done(tester, c);
  });
}
