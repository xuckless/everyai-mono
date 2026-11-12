import 'dart:async';

import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/ui/transcript/plan_card.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

Widget _host(Widget child) => m.MaterialApp(
  home: m.Material(
    child: EveryThemeScope(
      theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
      child: SingleChildScrollView(child: SizedBox(width: 640, child: child)),
    ),
  ),
);

void main() {
  group('CodeSessionState link and notice', () {
    test("a failed send is shown but doesn't fail the session", () {
      const live = CodeSessionState(link: SessionLink.live);
      final s = live.copyWith(notice: const SendFailed("Couldn't save the attachments: disk full"));
      expect(s.status, SessionStatus.idle);
      expect(s.failure, isNull);
      expect(s.error, contains('disk full'));
    });

    test('a spent budget fails the session; raising it leaves the link alone', () {
      final broken = const CodeSessionState().copyWith(link: SessionLink.broken, brokenBy: 'no server');
      final spent = broken.copyWith(notice: const BudgetReached('Budget reached'));
      expect(spent.status, SessionStatus.failed);
      // Raising the budget clears the note, not the connect failure under it.
      final raised = spent.copyWith(clearNotice: true);
      expect(raised.status, SessionStatus.failed);
      expect(raised.failure, 'no server');
      expect(
        const CodeSessionState(link: SessionLink.live).copyWith(notice: const BudgetReached('b')).status,
        SessionStatus.failed,
      );
    });
  });

  group('PlanCard', () {
    final plan = PlanProposal(
      HarnessEvent.decode({
        'kind': 'ActionEvent',
        'id': 'p',
        'tool_name': 'present_plan',
        'action': {
          'kind': 'PresentPlanAction',
          'title': 'Plan: counter',
          'summary': 'Add a counter.',
          'verification': 'Run the tests',
          'steps': [
            {
              'title': 'Add it',
              'detail': 'In main',
              'files': ['lib/main.dart'],
            },
          ],
        },
      }) as ActionCall,
    );

    testWidgets('opens again when Start building is refused', (tester) async {
      final answer = Completer<bool>();
      await tester.pumpWidget(
        _host(PlanCard(plan: plan, open: true, onApprove: () => answer.future, onRevise: (_) {})),
      );
      await tester.tap(find.text('Start building'));
      await tester.pump();
      expect(find.text('Start building'), findsNothing);
      answer.complete(false);
      await tester.pumpAndSettle();
      expect(find.text('Start building'), findsOneWidget);
    });
  });
}
