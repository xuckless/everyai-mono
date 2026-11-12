import 'package:everyai_markdown/everyai_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;

/// All top-level nodes of a parsed document.
List<md.Node> nodesOf(String source) => MarkdownDocument.parse(source).blocks.expand((b) => b.nodes).toList();

/// Depth-first list of all elements.
List<md.Element> elementsOf(List<md.Node> nodes) {
  final out = <md.Element>[];
  void walk(md.Node node) {
    if (node is md.Element) {
      out.add(node);
      node.children?.forEach(walk);
    }
  }

  nodes.forEach(walk);
  return out;
}

List<String> tagsOf(String source) => elementsOf(nodesOf(source)).map((e) => e.tag).toList();

md.Element firstTag(String source, String tag) => elementsOf(nodesOf(source)).firstWhere((e) => e.tag == tag);

String html(List<md.Node> nodes) => md.HtmlRenderer().render(nodes);

void main() {
  group('inline formatting', () {
    test('paragraph keeps full inline structure', () {
      final p =
          nodesOf(
                'Hello **bold** *it* ~~gone~~ `code` [link](https://a.dev) '
                'and https://auto.dev',
              ).single
              as md.Element;
      expect(p.tag, 'p');
      final tags = elementsOf([p]).map((e) => e.tag).toList();
      expect(tags, containsAll(<String>['strong', 'em', 'del', 'code', 'a']));
      final links = elementsOf([p]).where((e) => e.tag == 'a').toList();
      expect(links.map((a) => a.attributes['href']), <String>['https://a.dev', 'https://auto.dev']);
    });
  });

  group('blocks', () {
    test('nested lists and ordered start', () {
      const source = '3. one\n4. two\n   - nested\n     - deeper\n';
      final ol = nodesOf(source).single as md.Element;
      expect(ol.tag, 'ol');
      expect(ol.attributes['start'], '3');
      expect(tagsOf(source).where((t) => t == 'ul').length, 2);
    });

    test('fenced and indented code blocks', () {
      final fenced = firstTag('```dart\nvoid main() {}\n```', 'code');
      expect(fenced.attributes['class'], 'language-dart');
      expect(fenced.textContent, 'void main() {}\n');

      final indented = firstTag('para\n\n    indented code\n', 'code');
      expect(indented.textContent, 'indented code\n');
    });

    test('tables with alignment', () {
      const source = '| L | C | R |\n|:--|:-:|--:|\n| 1 | 2 | 3 |';
      final cells = elementsOf(nodesOf(source)).where((e) => e.tag == 'th' || e.tag == 'td').toList();
      expect(cells, hasLength(6));
      expect(cells.take(3).map((c) => c.attributes['align']), <String>['left', 'center', 'right']);
      expect(cells.last.textContent, '3');
    });

    test('link reference definitions resolve across blocks', () {
      final a = firstTag('[docs][ref]\n\n[ref]: https://ref.dev', 'a');
      expect(a.attributes['href'], 'https://ref.dev');
    });
  });

  group('math', () {
    md.Element mathOf(String source) => firstTag(source, 'math');
    List<md.Element> allMath(String source) => elementsOf(nodesOf(source)).where((e) => e.tag == 'math').toList();

    test('inline dollar math', () {
      final m = mathOf(r'Energy $E = mc^2$ here');
      expect(m.textContent, 'E = mc^2');
      expect(m.attributes['display'], 'false');
    });

    test('unterminated \$\$ renders as plain text', () {
      final doc = MarkdownDocument.parse('Intro\n\n\$\$\na + b');
      expect(doc.blocks.last.isOpen, isTrue);
      final p = doc.blocks.last.nodes.single as md.Element;
      expect(p.tag, 'p');
      expect(p.textContent, '\$\$a + b');
      expect(p.children!.whereType<md.Element>().single.tag, 'br');
      expect(tagsOf('Intro\n\n\$\$\na + b'), isNot(contains('math-block')));
    });

    group('currency is not math', () {
      test(r'$5 and $10', () {
        expect(allMath(r'It costs $5 and $10 later.'), isEmpty);
      });
    });
  });

  group('appendParse', () {
    test('reuses earlier blocks and re-parses the tail', () {
      const first = '# Title\n\nPara one.\n\nPara two\nand mo';
      const second =
          '$first'
          're.\n\n- item\n';
      final previous = MarkdownDocument.parse(first);
      expect(previous.blocks, hasLength(3));

      final next = MarkdownDocument.appendParse(previous, second);
      expect(next.source, second);
      expect(next.blocks, hasLength(4));
      expect(identical(next.blocks[0], previous.blocks[0]), isTrue);
      expect(identical(next.blocks[1], previous.blocks[1]), isTrue);
      expect(identical(next.blocks[2], previous.blocks[2]), isFalse);
      expect(next.blocks[2].nodes.single.textContent, 'Para two\nand more.');
      expect(html(next.blocks[3].nodes), contains('<li>item</li>'));
      expect(next.isIncremental, isTrue);
    });

    test('streaming char by char matches a full parse', () {
      const source =
          '# Streaming test\n\n'
          'Intro with **bold**, \$x^2\$ and a [link](https://a.dev).\n\n'
          '1. first\n\n'
          '2. second\n   - nested\n\n'
          '10. tenth\n\n'
          '```dart\nvoid main() {\n\n  print(1);\n}\n```\n\n'
          '\$\$\n\\int_0^1 x\\,dx\n\n= 1/2\n\$\$\n\n'
          '| a | b |\n|---|--:|\n| 1 | 2 |\n\n'
          '> quote\n>\n> more\n\n'
          'Setext\n------\n\n'
          '    indented\n\n'
          '[^1]: The note.\n\n'
          'Footnote ref[^1].\n\n'
          '---\n\nThe end.\n';
      var doc = MarkdownDocument.parse('');
      for (var i = 1; i <= source.length; i++) {
        final prefix = source.substring(0, i);
        doc = MarkdownDocument.appendParse(doc, prefix);
        final full = MarkdownDocument.parse(prefix);
        final incrementalHtml = html(doc.blocks.expand((b) => b.nodes).toList());
        final fullHtml = html(full.blocks.expand((b) => b.nodes).toList());
        expect(incrementalHtml, fullHtml, reason: 'prefix length $i');
      }
      expect(doc.blocks.length, greaterThan(10));
    });
  });
}
