// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';

import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/harness/events.dart' show PlanWindow;
import 'package:every_ai/features/code/workflows/ui/proposal_card.dart';
import 'package:every_ai/features/code/workflows/workflow_estimate.dart';
import 'package:every_ai/features/code/workflows/workflow_proposal.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

Widget _app(Widget child) => m.MaterialApp(
  home: m.Material(
    child: EveryThemeScope(
      theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
      child: SingleChildScrollView(child: child),
    ),
  ),
);

const _proposal = WorkflowProposal(
  id: 'p1',
  workflowId: 'ultra',
  title: 'Ultra',
  args: {},
  ctx: {},
  estimate: WorkflowEstimate(
    agents: (9, 12),
    planWindows: [PlanWindow(name: 'five_hour', used: 0.22, minutes: 300)],
  ),
  phases: ['Split', 'Research'],
  items: ['Dark mode', 'Settings page'],
);

void main() {
  testWidgets('the card shows the items and estimate; Start goes once however often it is clicked', (tester) async {
    var starts = 0, cancels = 0, adjusts = 0;
    final done = Completer<void>();
    await tester.pumpWidget(
      _app(
        ProposalCard(
          proposal: _proposal,
          onStart: () {
            starts++;
            return done.future;
          },
          onAdjust: () => adjusts++,
          onCancel: () => cancels++,
        ),
      ),
    );
    expect(find.text('Ultra · 2 items'), findsOneWidget);
    expect(find.text('Split → Research'), findsOneWidget);
    expect(find.text('~9–12 agents'), findsOneWidget);
    expect(find.text('5-hour window: 22% used'), findsOneWidget);
    expect(find.textContaining('No money cap'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('workflow-proposal.start')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('workflow-proposal.start')));
    await tester.tap(find.byKey(const ValueKey('workflow-proposal.cancel')));
    await tester.pump();
    expect(starts, 1);
    expect(cancels, 0, reason: 'busy while the start is on its way');
    done.complete();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('workflow-proposal.adjust')));
    expect(adjusts, 1);
  });
}
