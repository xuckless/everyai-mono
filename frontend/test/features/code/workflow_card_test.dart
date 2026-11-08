// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/workflows/ui/workflow_card.dart';
import 'package:every_ai/features/code/workflows/workflow_engine.dart';
import 'package:every_ai/features/code/workflows/workflow_runs.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

Widget _card(WorkflowCard card) => m.MaterialApp(
  home: m.Material(
    child: EveryThemeScope(
      theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
      child: SingleChildScrollView(child: card),
    ),
  ),
);

void main() {
  _rowsAndDecision();
  testWidgets('a finished workflow card can be dismissed; a running one has no dismiss', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final runs = container.read(workflowRunsProvider('s').notifier);
    runs.put(const WorkflowRun(runId: 'done', name: 'Ultra', state: RunEnded(WorkflowOutcome.done)));
    runs.put(const WorkflowRun(runId: 'live', name: 'Bug fix'));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: m.MaterialApp(
          home: m.Material(
            child: EveryThemeScope(
              theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
              child: const SingleChildScrollView(child: WorkflowRunsView(sessionId: 's')),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Workflow: Ultra'), findsOneWidget);
    expect(find.byKey(const ValueKey('workflow.dismiss.live')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('workflow.dismiss.done')));
    await tester.pump();
    expect(find.text('Workflow: Ultra'), findsNothing);
    expect(find.text('Workflow: Bug fix'), findsOneWidget);
    // Still listed for Running work.
    expect(container.read(workflowRunsProvider('s')), hasLength(2));
  });

  testWidgets('a finished run shows its summary and folds the JSON under Details; a running one shows neither', (
    tester,
  ) async {
    const done = WorkflowRun(
      runId: 'r1',
      name: 'Bug fix',
      state: RunEnded(WorkflowOutcome.done),
      started: 2,
      result: {'verified': true, 'cause': 'off by one', 'fix_summary': 'uses <='},
    );
    await tester.pumpWidget(_card(const WorkflowCard(run: done)));
    expect(find.text('Workflow: Bug fix'), findsOneWidget);
    expect(find.textContaining('Cause: off by one'), findsOneWidget);
    expect(find.text('Details'), findsOneWidget);
    expect(find.textContaining('"cause": "off by one"'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('workflow.details.r1')));
    await tester.pump();
    expect(find.textContaining('"cause": "off by one"'), findsOneWidget);

    await tester.pumpWidget(
      _card(
        const WorkflowCard(
          run: WorkflowRun(runId: 'r2', name: 'Bug fix', result: {'verified': true}),
        ),
      ),
    );
    expect(find.text('Details'), findsNothing);
  });

  testWidgets('the landing row offers three choices and each calls back; once chosen it says what happened', (
    tester,
  ) async {
    final calls = <String>[];
    const done = WorkflowRun(runId: 'r1', name: 'Ultra', state: RunEnded(WorkflowOutcome.done));
    Widget row({String? error}) => _card(
      WorkflowCard(
        run: done,
        landing: WorkflowLanding(
          onCommit: () => calls.add('commit'),
          onBranch: () => calls.add('branch'),
          onLeave: () => calls.add('leave'),
          error: error,
        ),
      ),
    );
    await tester.pumpWidget(row(error: 'There is a branch called x already.'));
    expect(find.text('There is a branch called x already.'), findsOneWidget);
    for (final label in ['Commit here', 'New branch', 'Leave uncommitted']) {
      await tester.tap(find.text(label));
    }
    expect(calls, ['commit', 'branch', 'leave']);

    await tester.pumpWidget(
      _card(const WorkflowCard(run: done, landing: WorkflowLanding.chosen('Committed abc1234.'))),
    );
    expect(find.text('Committed abc1234.'), findsOneWidget);
    expect(find.text('Commit here'), findsNothing);

    await tester.pumpWidget(_card(const WorkflowCard(run: done)));
    expect(find.text('Commit here'), findsNothing);
  });
}

void _rowsAndDecision() {
  testWidgets('report rows sit under their phase; past the estimate the card asks Continue or Adjust', (tester) async {
    var continued = 0, adjusted = 0, resumed = 0;
    await tester.pumpWidget(
      _card(
        WorkflowCard(
          run: const WorkflowRun(
            runId: 'r',
            name: 'Ultra',
            state: RunPaused('Build', PauseReason.overEstimate),
            phases: ['Research', 'Build'],
            rows: [
              (kind: RowKind.phase, phase: 'Research', text: 'Research done · 3 agents · \$0.42 · 6m 0s'),
              (kind: RowKind.mark, phase: 'Build', text: '50% of the estimate used'),
              (
                kind: RowKind.over,
                phase: 'Build',
                text: 'Past the estimate: \$3.20 of \$3.10. Paused until you decide.',
              ),
            ],
          ),
          onStop: () {},
          onResume: () => resumed++,
          onContinue: () => continued++,
          onAdjust: () => adjusted++,
        ),
      ),
    );
    expect(find.text('Past its estimate'), findsOneWidget);
    expect(find.text('Research done · 3 agents · \$0.42 · 6m 0s'), findsOneWidget);
    expect(find.text('50% of the estimate used'), findsOneWidget);
    expect(find.byKey(const ValueKey('workflow.resume.r')), findsNothing, reason: 'Continue is the way on');
    await tester.tap(find.byKey(const ValueKey('workflow.continue.r')));
    await tester.tap(find.byKey(const ValueKey('workflow.adjust.r')));
    expect((continued, adjusted, resumed), (1, 1, 0));
  });
}
