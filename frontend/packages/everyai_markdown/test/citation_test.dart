import 'package:everyai_markdown/everyai_markdown.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;

/// Depth-first list of all elements in a parsed document.
List<md.Element> elementsOf(String source) {
  final out = <md.Element>[];
  void walk(md.Node node) {
    if (node is md.Element) {
      out.add(node);
      node.children?.forEach(walk);
    }
  }

  for (final block in MarkdownDocument.parse(source).blocks) {
    block.nodes.forEach(walk);
  }
  return out;
}

/// Citation numbers found in [source], in order.
List<int> citations(String source) =>
    elementsOf(source)
        .where((e) => e.tag == 'citation')
        .map((e) => int.parse(e.attributes['index']!))
        .toList();

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

void main() {
  group('citation parsing', () {
    test('bracketed integers become citations', () {
      expect(citations('Paris is the capital [1].'), <int>[1]);
      expect(citations('Sources agree [1][3] and [12].'), <int>[1, 3, 12]);
      expect(citations('First [2]\nsecond line [4]'), <int>[2, 4]);
      expect(citations('Inline [7]: not a definition'), <int>[7]);
      expect(citations('- item [1]\n- item [2]'), <int>[1, 2]);
      expect(citations('| a |\n|---|\n| cell [5] |'), <int>[5]);
    });

    test('citations keep their marker as text content', () {
      final p = MarkdownDocument.parse('See [1].').blocks.single.nodes.single;
      expect(p.textContent, 'See [1].');
    });

    test('inline links are not citations', () {
      expect(citations('[1](https://a.dev)'), isEmpty);
      expect(citations('[1](x)'), isEmpty);
      final link = elementsOf('[1](x)').singleWhere((e) => e.tag == 'a');
      expect(link.attributes['href'], 'x');
      expect(link.textContent, '1');
    });

    test('reference definitions and reference links are not citations', () {
      const source =
          'See [1] and [docs][2].\n\n[1]: https://one.dev\n[2]: https://two.dev';
      expect(citations(source), isEmpty);
      final hrefs = elementsOf(source)
          .where((e) => e.tag == 'a')
          .map((e) => e.attributes['href']);
      expect(hrefs, <String>['https://one.dev', 'https://two.dev']);
      // A numeric full reference link to a defined label.
      expect(citations('Read [1][2].\n\n[2]: https://two.dev'), isEmpty);
      // A non-numeric label after the number is a (possible) reference link.
      expect(citations('[1][a]'), isEmpty);
    });

    test('citations inside link text stay plain text', () {
      final elements = elementsOf('[see [1]](https://a.dev) then [2]');
      final link = elements.singleWhere((e) => e.tag == 'a');
      expect(link.textContent, 'see [1]');
      expect(
        link.children!.whereType<md.Element>().where(
          (e) => e.tag == 'citation',
        ),
        isEmpty,
      );
      expect(citations('[see [1]](https://a.dev) then [2]'), <int>[2]);
    });

    test('code spans and code blocks never contain citations', () {
      expect(citations('Index with `list[1]` here.'), isEmpty);
      expect(citations('```python\nx = a[1]\n```'), isEmpty);
      expect(citations('    indented [1]'), isEmpty);
    });

    test('non-numeric and out-of-range brackets are not citations', () {
      expect(citations('[a]'), isEmpty);
      expect(citations('[1a] [ 1 ] [-1] [1.5]'), isEmpty);
      expect(citations('[0] and [1000]'), isEmpty);
      expect(citations('A footnote[^1].\n\n[^1]: Body.'), isEmpty);
      expect(citations('- [ ] task\n- [x] done'), isEmpty);
    });

    test('streaming parse matches a full parse', () {
      var document = MarkdownDocument.parse('');
      const text = 'Alpha [1].\n\nBeta [2][3].';
      for (var i = 1; i <= text.length; i++) {
        document = MarkdownDocument.appendParse(document, text.substring(0, i));
      }
      final streamed = document.blocks
          .expand((b) => b.nodes)
          .map((n) => md.HtmlRenderer().render(<md.Node>[n]))
          .join();
      final full = MarkdownDocument.parse(text).blocks
          .expand((b) => b.nodes)
          .map((n) => md.HtmlRenderer().render(<md.Node>[n]))
          .join();
      expect(streamed, full);
      expect(citations(text), <int>[1, 2, 3]);
    });
  });

  group('citation rendering', () {
    testWidgets('renders chips and reports taps', (tester) async {
      final taps = <int>[];
      await tester.pumpWidget(
        host(
          MarkdownView(
            data: 'Paris is the capital of France [1][3].',
            style: style,
            onTapCitation: taps.add,
          ),
        ),
      );
      expect(find.byType(CitationChip), findsNWidgets(2));
      expect(find.text('1'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);

      await tester.tap(find.text('3'));
      await tester.tap(find.text('1'));
      expect(taps, <int>[3, 1]);
    });

    testWidgets('uses a custom citation builder', (tester) async {
      await tester.pumpWidget(
        host(
          MarkdownView(
            data: 'Claim [2].',
            style: style,
            citationBuilder: (context, index) => Text('src-$index'),
          ),
        ),
      );
      expect(find.byType(CitationChip), findsNothing);
      expect(find.text('src-2'), findsOneWidget);
    });

    testWidgets('citations in links and code render as text', (tester) async {
      await tester.pumpWidget(
        host(
          MarkdownView(
            data: '[see [1]](https://a.dev) and `a[2]`',
            style: style,
            onTapLink: (_) {},
            onTapCitation: (_) {},
          ),
        ),
      );
      expect(find.byType(CitationChip), findsNothing);
      expect(find.textContaining('see [1]'), findsOneWidget);
      expect(find.text('a[2]'), findsOneWidget);
    });

    testWidgets('chips are not tappable without onTapCitation', (tester) async {
      await tester.pumpWidget(
        host(MarkdownView(data: 'Claim [4].', style: style)),
      );
      expect(find.byType(CitationChip), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byType(CitationChip),
          matching: find.byType(GestureDetector),
        ),
        findsNothing,
      );
    });
  });
}
