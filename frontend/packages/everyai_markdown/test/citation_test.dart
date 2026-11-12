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
    elementsOf(source).where((e) => e.tag == 'citation').map((e) => int.parse(e.attributes['index']!)).toList();

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

    test('code spans and code blocks never contain citations', () {
      expect(citations('Index with `list[1]` here.'), isEmpty);
      expect(citations('```python\nx = a[1]\n```'), isEmpty);
      expect(citations('    indented [1]'), isEmpty);
    });

    test('streaming parse matches a full parse', () {
      var document = MarkdownDocument.parse('');
      const text = 'Alpha [1].\n\nBeta [2][3].';
      for (var i = 1; i <= text.length; i++) {
        document = MarkdownDocument.appendParse(document, text.substring(0, i));
      }
      final streamed = document.blocks.expand((b) => b.nodes).map((n) => md.HtmlRenderer().render(<md.Node>[n])).join();
      final full = MarkdownDocument.parse(text).blocks
          .expand((b) => b.nodes)
          .map((n) => md.HtmlRenderer().render(<md.Node>[n]))
          .join();
      expect(streamed, full);
      expect(citations(text), <int>[1, 2, 3]);
    });
  });

  group('citation rendering', () {});
}
