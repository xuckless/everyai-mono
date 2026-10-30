import 'package:everyai_markdown/everyai_markdown.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

final MarkdownStyle style = MarkdownStyle.fallback(Brightness.light);

Widget host(Widget child) => MediaQuery(
  data: const MediaQueryData(size: Size(800, 1200)),
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: 600, child: SingleChildScrollView(child: child)),
    ),
  ),
);

void main() {
  // A PDF converted to Markdown put TeX in table cells; measuring the cells
  // asked flutter_math_fork for a dry baseline it can't give, and layout
  // failed on every frame (the app froze in debug builds).
  testWidgets('inline math in a table cell lays out', (tester) async {
    await tester.pumpWidget(
      host(
        MarkdownView(
          data: '| Action | Probability |\n|---|---|\n| Intended | \$P = 0.8\$ |\n| Slip | \$\\frac{0.2}{2}\$ |\n',
          style: style,
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(Table), findsOneWidget);
  });

  testWidgets('inline math inside an intrinsic-width parent lays out', (tester) async {
    await tester.pumpWidget(
      host(
        IntrinsicWidth(
          child: MarkdownView(data: r"The update is $Q(s,a) \leftarrow r + \gamma \max_{a'} Q(s',a')$.", style: style),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
