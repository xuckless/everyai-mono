import 'dart:async';

import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/ui/transcript/plan_card.dart';
import 'package:every_ai/features/questions/domain/questions.dart';
import 'package:every_ai/features/questions/ui/question_card.dart';
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

List<Question> _questions(String header) => Question.listFrom({
  'questions': [
    {
      'question': 'Which $header?',
      'header': header,
      'multi_select': false,
      'options': [
        {'label': '$header A', 'description': 'first'},
        {'label': '$header B', 'description': 'second'},
      ],
    },
  ],
});

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

    test('a reconnect is not a failure, and a mirrored snapshot maps to a link', () {
      expect(const CodeSessionState(link: SessionLink.reconnecting).status, SessionStatus.starting);
      expect(const CodeSessionState(connected: true).link, SessionLink.live);
      const mirrored = CodeSessionState(connected: true, error: 'gone');
      expect(mirrored.link, SessionLink.broken);
      expect(mirrored.status, SessionStatus.failed);
      expect(mirrored.brokenBy, 'gone');
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

    testWidgets('stays closed once the approval went out', (tester) async {
      await tester.pumpWidget(_host(PlanCard(plan: plan, open: true, onApprove: () async => true, onRevise: (_) {})));
      await tester.tap(find.text('Start building'));
      await tester.pumpAndSettle();
      expect(find.text('Start building'), findsNothing);
    });
  });

  group('QuestionCard', () {
    testWidgets('a new question in the same place starts fresh', (tester) async {
      final sent = <List<QuestionAnswer>>[];
      Widget card(List<Question> q) => _host(QuestionCard(questions: q, onSubmit: sent.add));
      await tester.pumpWidget(card(_questions('Platform')));
      await tester.tap(find.text('Platform B'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('question.submit')));
      await tester.pumpAndSettle();
      expect(sent.single.single.selected, {1});
      // The next ask arrives while the card stays mounted.
      await tester.pumpWidget(card(_questions('Review')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review A'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('question.submit')));
      await tester.pumpAndSettle();
      expect(sent, hasLength(2));
      expect(sent.last.single.selected, {0});
    });

    testWidgets('opens again when sending the answers throws', (tester) async {
      var tries = 0;
      await tester.pumpWidget(
        _host(
          QuestionCard(
            questions: _questions('Platform'),
            onSubmit: (_) {},
            onSubmitWithFiles: (_, _) async {
              tries++;
              throw StateError('no session');
            },
          ),
        ),
      );
      await tester.tap(find.text('Platform A'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('question.submit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('question.submit')));
      await tester.pumpAndSettle();
      expect(tries, 2);
    });
  });
}
