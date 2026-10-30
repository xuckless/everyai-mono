import 'dart:convert';

import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/ultra/domain/ultra_journal.dart';
import 'package:every_ai/features/code/ultra/domain/ultra_plan.dart';
import 'package:every_ai/features/code/ultra/ui/ultra_run_card.dart';
import 'package:every_ai/features/code/ultra/ui/ultra_toggle.dart';
import 'package:every_ai/features/code/ultra/ultra_providers.dart';
import 'package:every_ai/features/code/ultra/ultra_ui_providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

CodeSessionInfo _session(String id, {String dir = '/work/app', String? parent}) => CodeSessionInfo(
  id: id,
  projectId: 'p1',
  title: 'Session $id',
  conversationId: 'c-$id',
  model: 'anthropic/claude-haiku-5.5',
  mode: AgentMode.autoEdit,
  workingDir: dir,
  createdAt: DateTime(2026),
  parentId: parent,
);

UltraJournal _journal({UltraRunStatus status = UltraRunStatus.running}) {
  final plan = parseUltraPlan({
    'goal': 'Port the app to Riverpod 3',
    'phases': [
      {
        'id': 'scan',
        'title': 'Survey',
        'for_each': ['lib/a', 'lib/b', 'lib/c'],
        'steps': [
          {'id': 'read', 'title': 'Read', 'prompt': 'Read {{item}}'},
        ],
      },
      {
        'id': 'fix',
        'title': 'Port',
        'steps': [
          {'id': 'port', 'title': 'Port it', 'prompt': 'Port', 'writes': true},
        ],
      },
    ],
  }).plan!;
  final start = DateTime(2026, 10, 30, 9);
  return UltraJournal(
    runId: 'run-1',
    sessionId: 's1',
    orchestratorId: 'orch',
    plan: plan,
    limits: const UltraLimits(),
    createdAt: start,
    status: status,
    elapsed: const Duration(minutes: 12, seconds: 5),
    budgetMicros: 25000000,
    agentsStarted: 3,
    steps: {
      'scan.read[0]': StepRecord(
        key: 'scan.read[0]',
        phaseId: 'scan',
        stepId: 'read',
        title: 'Read',
        item: 'lib/a',
        status: StepStatus.done,
        attempts: 1,
        childIds: const ['child-a'],
        costMicros: 420000,
        startedAt: start,
        endedAt: start.add(const Duration(minutes: 2, seconds: 10)),
      ),
      'scan.read[1]': StepRecord(
        key: 'scan.read[1]',
        phaseId: 'scan',
        stepId: 'read',
        title: 'Read',
        item: 'lib/b',
        status: StepStatus.failed,
        attempts: 1,
        childIds: const ['child-gone'],
        costMicros: 10000,
        note: 'The agent ran out of steps.',
        startedAt: start,
        endedAt: start.add(const Duration(seconds: 40)),
      ),
      'scan.read[2]': StepRecord(
        key: 'scan.read[2]',
        phaseId: 'scan',
        stepId: 'read',
        title: 'Read',
        item: 'lib/c',
        status: StepStatus.running,
        attempts: 1,
        childIds: const ['child-c'],
        startedAt: start,
      )..liveCostMicros = 50000,
    },
  );
}

Widget _app(Widget child, {required List<Override> overrides, Preferences? prefs}) => ProviderScope(
  overrides: [
    preferencesProvider.overrideWithValue(
      prefs ??
          Preferences.inMemory({
            'code.sessions': jsonEncode([
              for (final s in [_session('s1'), _session('child-a', parent: 's1'), _session('orch', parent: 's1')])
                s.toJson(),
            ]),
          }),
    ),
    ...overrides,
  ],
  child: m.MaterialApp(
    home: EveryThemeScope(
      theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
      child: m.Scaffold(
        body: Align(alignment: Alignment.topLeft, child: child),
      ),
    ),
  ),
);

void main() {
  group('caps', () {
    test('step through the presets within the plan', () {
      expect(UltraCapSteps.next(UltraCapSteps.agents, 150, 1, 150), 150);
      expect(UltraCapSteps.next(UltraCapSteps.agents, 150, -1, 150), 100);
      expect(UltraCapSteps.next(UltraCapSteps.agents, 5, -1, 150), 5);
      // Between presets, and a plan ceiling that isn't a preset.
      expect(UltraCapSteps.next(UltraCapSteps.dollars, 7, 1, 25), 10);
      expect(UltraCapSteps.next(UltraCapSteps.dollars, 10, 1, 12), 12);
      expect(UltraCapSteps.next(UltraCapSteps.concurrent, 16, 1, 16), 16);
    });

    test('clamp to the plan and to sane floors', () {
      final l = clampUltraLimits(
        const UltraLimits(maxConcurrent: 40, maxAgents: 0, budgetMicros: 90000000, wallTime: Duration(minutes: 1)),
        const UltraLimits(),
      );
      expect(l.maxConcurrent, 16);
      expect(l.maxAgents, 1);
      expect(l.budgetMicros, 25000000);
      expect(l.wallTime, const Duration(minutes: 5));
    });

    test('only Max has Ultra', () {
      expect(ultraPlanLimits('max')?.maxAgents, 150);
      expect(ultraPlanLimits('pro'), isNull);
      expect(ultraPlanLimits('free'), isNull);
    });

    test('durations read short', () {
      expect(formatUltraDuration(const Duration(seconds: 45)), '45s');
      expect(formatUltraDuration(const Duration(minutes: 3, seconds: 5)), '3m 05s');
      expect(formatUltraDuration(const Duration(hours: 2)), '2h');
      expect(formatUltraDuration(const Duration(hours: 1, minutes: 2)), '1h 02m');
    });
  });

  group('run entries', () {
    test('a journal from an earlier app run can be resumed unless it finished', () {
      final cut = UltraRunEntry.fromJournal(_journal());
      expect(cut.active, isFalse);
      expect(cut.resumable, isTrue);
      expect(cut.error, contains('app closed'));
      expect(UltraRunEntry.fromJournal(_journal(status: UltraRunStatus.stopped)).resumable, isTrue);
      expect(UltraRunEntry.fromJournal(_journal(status: UltraRunStatus.done)).resumable, isFalse);
      expect(UltraRunEntry.fromJournal(_journal(status: UltraRunStatus.capped)).resumable, isFalse);
    });

    test('a live run is active until it settles', () {
      final v = UltraRunView(runId: 'r', sessionId: 's1', orchestratorId: 'o', goal: 'g', journal: _journal());
      expect(UltraRunEntry.fromView(v).active, isTrue);
      expect(UltraRunEntry.fromView(v.copyWith(stage: UltraStage.running)).resumable, isFalse);
      expect(UltraRunEntry.fromView(v.copyWith(stage: UltraStage.done)).active, isFalse);
    });

    test('the summary states the totals against the caps', () {
      final line = ultraSummaryLine(UltraRunEntry.fromJournal(_journal(status: UltraRunStatus.done)));
      expect(line, startsWith('Done · 3 of 150 agents · \$0.48 of \$25.00 · 12m 05s of 2h'));
    });

    test('the hand-off carries the goal and the report', () {
      const e = UltraRunEntry(
        runId: 'r',
        sessionId: 's1',
        goal: 'Port it',
        stage: UltraStage.done,
        live: true,
        answer: 'All ported.',
      );
      expect(ultraHandoff(e), allOf(contains('Port it'), contains('All ported.')));
    });

    test('a session lists saved runs before live ones, without repeats', () async {
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(Preferences.inMemory()),
          ultraSavedRunsProvider('s1').overrideWith((ref) async => [_journal()]),
        ],
      );
      addTearDown(container.dispose);
      await container.read(ultraSavedRunsProvider('s1').future);
      final runs = container.read(sessionUltraRunsProvider('s1'));
      expect(runs.single.runId, 'run-1');
      expect(runs.single.live, isFalse);
    });
  });

  group('toggle', () {
    testWidgets('Max: arms the next message and edits the caps', (tester) async {
      await tester.pumpWidget(
        _app(
          const UltraChip(sessionId: 's1'),
          overrides: [
            ultraAccessProvider.overrideWith((ref) async => const UltraLimits()),
            ultraSavedRunsProvider('s1').overrideWith((ref) async => const <UltraJournal>[]),
          ],
        ),
      );
      await tester.pump();
      final container = ProviderScope.containerOf(tester.element(find.byType(UltraChip)));
      await tester.tap(find.byKey(const ValueKey('ultra.chip')));
      await tester.pumpAndSettle();
      expect(find.text('Plan a goal and fan it out to many agents at once'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('ultra.toggle')));
      await tester.pump();
      expect(container.read(ultraToggleProvider('s1')).armed, isTrue);

      // The caps start at the plan's ceiling, so + stays and − steps down.
      await tester.tap(find.byKey(const ValueKey('+In total')));
      await tester.tap(find.byKey(const ValueKey('−In total')));
      await tester.tap(find.byKey(const ValueKey('−Spend')));
      await tester.tap(find.byKey(const ValueKey('−Wall time')));
      await tester.pump();
      final l = container.read(ultraToggleProvider('s1')).limits;
      expect(l.maxAgents, 100);
      expect(l.budgetMicros, 20000000);
      expect(l.wallTime, const Duration(minutes: 90));
      expect(find.text('100 agents'), findsOneWidget);

      await tester.ensureVisible(find.byKey(const ValueKey('ultra.reset')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ultra.reset')));
      await tester.pump();
      expect(container.read(ultraToggleProvider('s1')).limits.maxAgents, 150);
    });

    testWidgets('off the Max plan it is locked', (tester) async {
      await tester.pumpWidget(
        _app(
          const UltraChip(sessionId: 's1'),
          overrides: [
            ultraAccessProvider.overrideWith((ref) async => null),
            ultraSavedRunsProvider('s1').overrideWith((ref) async => const <UltraJournal>[]),
          ],
        ),
      );
      await tester.pump();
      expect(find.text('Max'), findsOneWidget);
      final container = ProviderScope.containerOf(tester.element(find.byType(UltraChip)));
      await tester.tap(find.byKey(const ValueKey('ultra.chip')));
      await tester.pumpAndSettle();
      expect(find.text('Part of the Max plan'), findsOneWidget);
      expect(find.byKey(const ValueKey('ultra.upgrade')), findsOneWidget);
      expect(find.byKey(const ValueKey('ultra.cap.agents')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('ultra.toggle')));
      await tester.pump();
      expect(container.read(ultraToggleProvider('s1')).armed, isFalse);
    });

    testWidgets('hidden in child sessions and the demo', (tester) async {
      await tester.pumpWidget(
        _app(
          const Column(
            children: [
              UltraChip(sessionId: 'child-a'),
              UltraChip(sessionId: 'demo'),
            ],
          ),
          prefs: Preferences.inMemory({
            'code.sessions': jsonEncode([
              _session('child-a', parent: 's1').toJson(),
              _session('demo', dir: 'demo://counter-app').toJson(),
            ]),
          }),
          overrides: [ultraAccessProvider.overrideWith((ref) async => const UltraLimits())],
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('ultra.chip')), findsNothing);
    });

    testWidgets('the composer banner shows the caps while armed', (tester) async {
      await tester.pumpWidget(_app(const UltraComposerBanner(sessionId: 's1'), overrides: const []));
      expect(find.byKey(const ValueKey('ultra.banner')), findsNothing);
      final container = ProviderScope.containerOf(tester.element(find.byType(UltraComposerBanner)));
      container.read(ultraToggleProvider('s1').notifier).setArmed(true);
      await tester.pump();
      expect(find.textContaining('up to 150 agents (16 at once), \$25.00 and 2h'), findsOneWidget);
      await tester.tap(find.text('Turn off'));
      await tester.pump();
      expect(container.read(ultraToggleProvider('s1')).armed, isFalse);
    });
  });

  group('progress tree', () {
    testWidgets('phases, agent cards and resume for a run cut off by a quit', (tester) async {
      tester.view.physicalSize = const Size(900, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _app(
          SizedBox(width: 760, child: UltraRunCard(entry: UltraRunEntry.fromJournal(_journal()))),
          overrides: const [],
        ),
      );
      expect(find.text('Ultra · Port the app to Riverpod 3'), findsOneWidget);
      expect(find.byKey(const ValueKey('ultra.resume')), findsOneWidget);
      expect(find.byKey(const ValueKey('ultra.stop')), findsNothing);
      expect(find.byKey(const ValueKey('ultra.open-orchestrator')), findsOneWidget);
      expect(find.textContaining('Survey · parallel · 2/3 done'), findsOneWidget);
      expect(find.textContaining('Port · parallel · 0/1 done'), findsOneWidget);
      expect(find.text('1 waiting'), findsOneWidget);
      expect(find.text('Read: lib/a'), findsOneWidget);
      expect(find.text('Done · \$0.42 · 2m 10s'), findsOneWidget);
      expect(find.textContaining('Failed · \$0.01 · 40s'), findsOneWidget);
      expect(find.text('The agent ran out of steps.'), findsOneWidget);
      // Open links only to children that still exist.
      expect(find.byKey(const ValueKey('ultra.open.scan.read[0]')), findsOneWidget);
      expect(find.byKey(const ValueKey('ultra.open.scan.read[1]')), findsNothing);
      expect(find.textContaining('app closed'), findsOneWidget);
    });

    testWidgets('a live run shows Stop, the running cost and its answer', (tester) async {
      tester.view.physicalSize = const Size(900, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final entry = UltraRunEntry(
        runId: 'run-1',
        sessionId: 's1',
        goal: 'Port the app',
        stage: UltraStage.running,
        live: true,
        orchestratorId: 'orch',
        journal: _journal(),
      );
      await tester.pumpWidget(
        _app(
          SizedBox(width: 760, child: UltraRunCard(entry: entry)),
          overrides: const [],
        ),
      );
      expect(find.byKey(const ValueKey('ultra.stop')), findsOneWidget);
      expect(find.byKey(const ValueKey('ultra.resume')), findsNothing);
      expect(find.textContaining('Working · \$0.05'), findsOneWidget);
      expect(find.textContaining('Running · 3 of 150 agents'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));

      const done = UltraRunEntry(
        runId: 'run-2',
        sessionId: 's1',
        goal: 'Port the app',
        stage: UltraStage.done,
        live: true,
        answer: 'Everything is ported.',
      );
      await tester.pumpWidget(
        _app(
          const SizedBox(width: 760, child: UltraRunCard(entry: done)),
          overrides: const [],
        ),
      );
      expect(find.text('Everything is ported.'), findsOneWidget);
      expect(find.byKey(const ValueKey('ultra.handoff')), findsOneWidget);
      expect(find.byKey(const ValueKey('ultra.stop')), findsNothing);
    });
  });
}
