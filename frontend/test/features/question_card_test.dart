import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/domain/questions.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/ui/transcript/question_card.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

void main() {
  final args = {
    'questions': [
      for (final h in ['Platform', 'Review', 'Fields', 'Address'])
        {
          'question': 'Which $h?',
          'header': h,
          'multi_select': h == 'Fields',
          'options': [
            {'label': '$h A', 'description': 'first'},
            {'label': '$h B', 'description': 'second'},
          ],
        },
    ],
  };
  final call = HarnessEvent.decode({
    'kind': 'ActionEvent',
    'id': 'q',
    'tool_name': 'ask_user_question',
    'action': args,
  }) as ActionCall;
  final item = QuestionItem(call, Question.listFrom(args));

  Widget host(ValueChanged<List<QuestionAnswer>> onSubmit) => m.MaterialApp(
    home: m.Material(
      child: EveryThemeScope(
        theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
        child: SingleChildScrollView(
          child: QuestionCard(item: item, onSubmit: onSubmit),
        ),
      ),
    ),
  );

  testWidgets('a long questionnaire pages through its questions and submits them together', (tester) async {
    List<QuestionAnswer>? sent;
    await tester.pumpWidget(host((a) => sent = a));

    expect(find.text('1 of 4'), findsOneWidget);
    expect(find.text('Which Platform?'), findsOneWidget);
    expect(find.text('Which Review?'), findsNothing);

    // A single-choice pick moves on to the next question.
    await tester.tap(find.text('Platform B'));
    await tester.pumpAndSettle();
    expect(find.text('2 of 4'), findsOneWidget);

    // Number keys pick options on the current page.
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.pumpAndSettle();
    expect(find.text('Which Fields?'), findsOneWidget);
    expect(find.text('Select all that apply'), findsOneWidget);

    // Multi-select stays on the page; Next moves on.
    await tester.tap(find.text('Fields A'));
    await tester.tap(find.text('Fields B'));
    await tester.pump();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Still to answer: Address'), findsOneWidget);

    await tester.tap(find.text('Address A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Submit answers'));
    await tester.pump();

    expect(sent!.map((a) => a.selected), [
      {1},
      {0},
      {0, 1},
      {0},
    ]);
  });

  testWidgets('tabs jump between questions', (tester) async {
    await tester.pumpWidget(host((_) {}));
    await tester.tap(find.text('Address'));
    await tester.pumpAndSettle();
    expect(find.text('4 of 4'), findsOneWidget);
    expect(find.text('Which Address?'), findsOneWidget);
  });
}
