import 'package:everyai_markdown/everyai_markdown.dart';
import 'package:everyai_markdown/src/code/highlighter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

final MarkdownStyle light = MarkdownStyle.fallback(Brightness.light);
final MarkdownStyle dark = MarkdownStyle.fallback(Brightness.dark);

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

/// Every leaf [TextSpan] with its effective style, across all paragraphs.
Map<String, TextStyle> leafStyles(WidgetTester tester) {
  final out = <String, TextStyle>{};
  void visit(InlineSpan span, TextStyle? inherited) {
    final effective = inherited?.merge(span.style) ?? span.style;
    if (span is TextSpan) {
      if (span.text != null && effective != null) out[span.text!] = effective;
      span.children?.forEach((c) => visit(c, effective));
    }
  }

  for (final p in tester.renderObjectList<RenderParagraph>(
    find.byType(RichText),
  )) {
    visit(p.text, null);
  }
  return out;
}

BoxDecoration? decorationWithColor(WidgetTester tester, Color color) {
  for (final box in tester.widgetList<DecoratedBox>(
    find.byType(DecoratedBox),
  )) {
    final decoration = box.decoration;
    if (decoration is BoxDecoration && decoration.color == color) {
      return decoration;
    }
  }
  return null;
}

void main() {
  group('inline code', () {
    testWidgets('short spans render as a rounded, bordered chip', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(MarkdownView(data: 'Call `foo()` now.', style: light)),
      );
      expect(find.text('foo()'), findsOneWidget);
      final chip = decorationWithColor(tester, light.inlineCodeBackground);
      expect(chip, isNotNull);
      expect(chip!.borderRadius, isNotNull);
      expect((chip.border! as Border).top.color, light.inlineCodeBorder);

      final text = tester.widget<Text>(find.text('foo()'));
      expect(text.style!.fontFamily, light.inlineCode.fontFamily);
      expect(text.style!.color, light.inlineCode.color);
      expect(text.style!.fontSize, lessThan(light.body.fontSize!));
      expect(text.style!.backgroundColor, isNull);

      // The chip sits inside the paragraph, baseline-aligned.
      final span = tester
          .widget<RichText>(
            find.byWidgetPredicate(
              (w) => w is RichText && w.text.toPlainText().startsWith('Call'),
            ),
          )
          .text;
      final widgetSpans = <WidgetSpan>[];
      span.visitChildren((s) {
        if (s is WidgetSpan) widgetSpans.add(s);
        return true;
      });
      expect(widgetSpans.single.alignment, PlaceholderAlignment.baseline);
    });

    testWidgets('long spans and code in links fall back to text', (
      tester,
    ) async {
      final long = 'x' * 60;
      await tester.pumpWidget(
        host(
          MarkdownView(
            data: 'A `$long` and [`linked`](https://a.dev).',
            style: light,
            onTapLink: (_) {},
          ),
        ),
      );
      final styles = leafStyles(tester);
      expect(styles[long]!.backgroundColor, light.inlineCodeBackground);
      expect(styles['linked']!.backgroundColor, light.inlineCodeBackground);
      expect(find.text(long), findsNothing);
    });

    testWidgets('a backgroundColor on inlineCode does not paint behind chips', (
      tester,
    ) async {
      final style = light.copyWith(
        inlineCode: light.inlineCode.copyWith(
          backgroundColor: const Color(0xFFFF0000),
        ),
      );
      await tester.pumpWidget(host(MarkdownView(data: '`x`', style: style)));
      expect(
        tester.widget<Text>(find.text('x')).style!.backgroundColor,
        isNull,
      );
    });

    testWidgets('chip text is selectable and copied with the paragraph', (
      tester,
    ) async {
      SelectedContent? selected;
      await tester.pumpWidget(
        WidgetsApp(
          color: const Color(0xFFFFFFFF),
          builder: (context, _) => Overlay(
            initialEntries: <OverlayEntry>[
              OverlayEntry(
                builder: (context) => SelectableRegion(
                  selectionControls: emptyTextSelectionControls,
                  onSelectionChanged: (content) => selected = content,
                  child: MarkdownView(
                    data: 'Run `npm test` first [1].',
                    style: light,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      tester
          .state<SelectableRegionState>(find.byType(SelectableRegion))
          .selectAll(SelectionChangedCause.keyboard);
      await tester.pump();
      expect(selected, isNotNull);
      // Chip text is part of the selection, in reading order; the citation
      // chip is excluded so copied prose reads naturally.
      expect(selected!.plainText, 'Run npm test first .');
    });

    testWidgets('chips scale with headings', (tester) async {
      await tester.pumpWidget(
        host(
          MarkdownView(data: '# Title `code`\n\nBody `code2`', style: light),
        ),
      );
      final heading = tester.widget<Text>(find.text('code')).style!.fontSize!;
      final body = tester.widget<Text>(find.text('code2')).style!.fontSize!;
      expect(heading, greaterThan(body));
    });
  });

  group('code blocks', () {
    testWidgets('header shows language, Copy -> Copied for 2s', (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add(
              (call.arguments as Map<Object?, Object?>)['text']! as String,
            );
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await tester.pumpWidget(
        host(MarkdownView(data: '```rust\nfn main() {}\n```', style: dark)),
      );
      expect(find.text('rust'), findsOneWidget);
      expect(find.bySemanticsLabel('Copy code'), findsOneWidget);
      expect(decorationWithColor(tester, dark.codeHeaderBackground), isNotNull);

      await tester.tap(find.text('Copy'));
      await tester.pump();
      expect(copied, <String>['fn main() {}']);
      expect(find.text('Copied'), findsOneWidget);
      expect(find.text('Copy'), findsNothing);
      expect(find.bySemanticsLabel('Copied'), findsOneWidget);

      // Copying again restarts the timer.
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.tap(find.text('Copied'));
      await tester.pump(const Duration(milliseconds: 1500));
      expect(find.text('Copied'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Copy'), findsOneWidget);
    });

    testWidgets('wrap toggle switches between scrolling and wrapping', (
      tester,
    ) async {
      final line = List<String>.filled(40, 'word').join(' ');
      await tester.pumpWidget(
        host(MarkdownView(data: '```\n$line\n```', style: light)),
      );
      Text code() => tester.widget<Text>(find.text(line));
      expect(code().softWrap, isFalse);
      expect(
        find.ancestor(
          of: find.text(line),
          matching: find.byType(SingleChildScrollView),
        ),
        findsOneWidget,
      );
      expect(find.byType(RawScrollbar), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Wrap lines'));
      await tester.pump();
      expect(code().softWrap, isTrue);
      expect(
        find.ancestor(
          of: find.text(line),
          matching: find.byType(SingleChildScrollView),
        ),
        findsNothing,
      );
      expect(tester.getSize(find.text(line)).width, lessThanOrEqualTo(600));

      await tester.tap(find.bySemanticsLabel('Disable line wrap'));
      await tester.pump();
      expect(code().softWrap, isFalse);
    });

    testWidgets('code block uses 13px / 1.5 mono and a 12px radius', (
      tester,
    ) async {
      expect(light.codeBlock.fontSize, 13);
      expect(light.codeBlock.height, 1.5);
      await tester.pumpWidget(
        host(MarkdownView(data: '```\nx\n```', style: light)),
      );
      final box = decorationWithColor(tester, light.codeBlockBackground)!;
      expect(box.borderRadius, BorderRadius.circular(12));
    });
  });

  group('syntax themes', () {
    test('cover the common scopes', () {
      const scopes = <String>[
        'keyword', 'built_in', 'type', 'literal', 'number', 'string', //
        'regexp', 'comment', 'title', 'title.function', 'title.class',
        'attr', 'variable', 'params', 'meta', 'tag', 'name', 'attribute',
        'symbol', 'operator', 'punctuation', 'addition', 'deletion',
      ];
      for (final theme in <Map<String, TextStyle>>[
        oneDarkSyntaxTheme,
        githubLightSyntaxTheme,
      ]) {
        for (final scope in scopes) {
          expect(theme[scope], isNotNull, reason: scope);
        }
        expect(theme['comment']!.fontStyle, FontStyle.italic);
      }
      expect(MarkdownStyle.darkSyntaxTheme, same(oneDarkSyntaxTheme));
      expect(MarkdownStyle.lightSyntaxTheme, same(githubLightSyntaxTheme));
    });

    test('nested scopes resolve via prefixes and containers', () {
      const theme = oneDarkSyntaxTheme;
      expect(
        resolveSyntaxScope(theme, 'title.function.invoke'),
        theme['title.function'],
      );
      expect(
        resolveSyntaxScope(theme, 'title.class.inherited'),
        theme['title.class.inherited'],
      );
      expect(resolveSyntaxScope(theme, 'meta.prompt'), theme['meta.prompt']);
      expect(resolveSyntaxScope(theme, 'char.escape'), theme['char']);
      expect(
        resolveSyntaxScope(theme, 'title', containers: <String>['class']),
        theme['title.class'],
      );
      expect(
        resolveSyntaxScope(theme, 'title', containers: <String>['function']),
        theme['title.function'],
      );
      expect(resolveSyntaxScope(theme, 'class'), isNull);
      expect(resolveSyntaxScope(theme, 'language:css'), isNull);
      // highlight.js CSS-style keys with a trailing underscore still work.
      const legacy = <String, TextStyle>{
        'title.class_': TextStyle(color: Color(0xFF123456)),
      };
      expect(
        resolveSyntaxScope(legacy, 'title.class')!.color,
        const Color(0xFF123456),
      );
    });

    testWidgets('highlights real code with distinct colors', (tester) async {
      await tester.pumpWidget(
        host(
          MarkdownView(
            data:
                '```python\n'
                'class Greeter(Base):\n'
                '    def hello(self, name):\n'
                '        # say hi\n'
                '        return f"hi {name}" + str(42)\n'
                '```',
            style: dark,
          ),
        ),
      );
      final styles = leafStyles(tester);
      final theme = dark.syntaxTheme;
      expect(styles['class']!.color, theme['keyword']!.color);
      expect(styles['Greeter']!.color, theme['title.class']!.color);
      expect(styles['hello']!.color, theme['title.function']!.color);
      expect(styles['# say hi']!.color, theme['comment']!.color);
      expect(styles['# say hi']!.fontStyle, FontStyle.italic);
      expect(styles['42']!.color, theme['number']!.color);
      expect(styles['str']!.color, theme['built_in']!.color);
    });

    test('diff fences are highlighted', () {
      final span = CodeHighlighter.highlight(
        '+added\n-removed',
        'diff',
        base: const TextStyle(),
        theme: oneDarkSyntaxTheme,
      );
      final colors = <String, Color?>{};
      void visit(InlineSpan s, TextStyle? inherited) {
        final effective = inherited?.merge(s.style) ?? s.style;
        if (s is TextSpan) {
          if (s.text != null) colors[s.text!.trim()] = effective?.color;
          s.children?.forEach((c) => visit(c, effective));
        }
      }

      visit(span, null);
      expect(colors['+added'], oneDarkSyntaxTheme['addition']!.color);
      expect(colors['-removed'], oneDarkSyntaxTheme['deletion']!.color);
      expect(CodeHighlighter.resolve('patch'), 'diff');
      expect(span.toPlainText(), '+added\n-removed');
    });
  });

  group('blocks', () {
    testWidgets('tables: header tint, zebra stripes, rounded border', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          MarkdownView(
            data: '| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n| 5 | 6 |',
            style: light,
          ),
        ),
      );
      final table = tester.widget<Table>(find.byType(Table));
      final colors = table.children
          .map((r) => (r.decoration as BoxDecoration?)?.color)
          .toList();
      expect(colors, <Color?>[
        light.tableHeaderBackground,
        null,
        light.tableStripe,
        null,
      ]);
      expect(
        tester.widget<Text>(find.text('A')).textSpan!.style!.fontWeight,
        FontWeight.w600,
      );
      expect(find.byType(ClipRRect), findsWidgets);
      expect(find.byType(RawScrollbar), findsOneWidget);
    });

    testWidgets('headings get more space above than below', (tester) async {
      await tester.pumpWidget(
        host(
          MarkdownView(data: 'Intro\n\n## Section\n\nBody text', style: light),
        ),
      );
      final intro = tester.getRect(find.text('Intro'));
      final heading = tester.getRect(find.text('Section'));
      final body = tester.getRect(find.text('Body text'));
      final above = heading.top - intro.bottom;
      final below = body.top - heading.bottom;
      expect(above, greaterThan(below));
      expect(below, greaterThan(0));
    });

    testWidgets('ordered list markers share one right-aligned column', (
      tester,
    ) async {
      final items = List<String>.generate(10, (i) => '${i + 1}. item${i + 1}');
      await tester.pumpWidget(
        host(MarkdownView(data: items.join('\n'), style: light)),
      );
      final nine = tester.getRect(find.text('9.'));
      final ten = tester.getRect(find.text('10.'));
      expect(nine.right, moreOrLessEquals(ten.right, epsilon: 0.01));
      expect(
        tester.getTopLeft(find.text('item9')).dx,
        tester.getTopLeft(find.text('item10')).dx,
      );
    });

    testWidgets('links underline only while hovered', (tester) async {
      await tester.pumpWidget(
        host(
          MarkdownView(
            data: 'Go to [the docs](https://docs.dev) now.',
            style: light,
            onTapLink: (_) {},
          ),
        ),
      );
      TextDecoration? decorationOf(String text) =>
          leafStyles(tester)[text]?.decoration;
      expect(decorationOf('the docs'), anyOf(isNull, TextDecoration.none));

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(gesture.removePointer);
      final topLeft = tester.getTopLeft(find.textContaining('Go to'));
      // The test font is monospace with 1em-wide glyphs: "Go to " is 90px.
      await gesture.moveTo(topLeft + const Offset(120, 10));
      await tester.pump();
      expect(decorationOf('the docs'), TextDecoration.underline);

      await gesture.moveTo(topLeft + const Offset(500, 10));
      await tester.pump();
      expect(decorationOf('the docs'), anyOf(isNull, TextDecoration.none));
    });

    testWidgets('blockquote bar and rule render without errors', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          MarkdownView(data: '> quoted\n> text\n\n---\n\nafter', style: dark),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('quoted text'), findsOneWidget);
      expect(
        find.ancestor(
          of: find.text('quoted text'),
          matching: find.byType(CustomPaint),
        ),
        findsWidgets,
      );
    });
  });

  group('MarkdownStyle', () {
    test('new fields have fallbacks and take part in copyWith and ==', () {
      final a = MarkdownStyle.fallback(Brightness.dark);
      final b = MarkdownStyle.fallback(Brightness.dark);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a.inlineCodeBackground, const Color(0xFF2B2F3A));
      expect(a.inlineCodeBorder, const Color(0xFF3A3F4C));

      const red = Color(0xFFFF0000);
      final variants = <MarkdownStyle>[
        a.copyWith(inlineCodeBackground: red),
        a.copyWith(inlineCodeBorder: red),
        a.copyWith(codeHeaderBackground: red),
        a.copyWith(tableHeaderBackground: red),
        a.copyWith(tableStripe: red),
        a.copyWith(citationBackground: red),
        a.copyWith(citationText: red),
      ];
      for (final v in variants) {
        expect(v, isNot(a));
      }
      expect(variants[0].inlineCodeBackground, red);
      expect(variants[6].citationText, red);
      expect(variants[6].inlineCodeBackground, a.inlineCodeBackground);
    });
  });
}
