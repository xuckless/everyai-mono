import 'package:everyai_markdown/everyai_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;

/// All top-level nodes of a parsed document.
List<md.Node> nodesOf(String source) =>
    MarkdownDocument.parse(source).blocks.expand((b) => b.nodes).toList();

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

List<String> tagsOf(String source) =>
    elementsOf(nodesOf(source)).map((e) => e.tag).toList();

md.Element firstTag(String source, String tag) =>
    elementsOf(nodesOf(source)).firstWhere((e) => e.tag == tag);

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
      expect(links.map((a) => a.attributes['href']), <String>[
        'https://a.dev',
        'https://auto.dev',
      ]);
    });

    test('HTML-sensitive characters are not escaped', () {
      final p = nodesOf('a < b && c > d').single as md.Element;
      expect(p.textContent, 'a < b && c > d');
      final code = firstTag('```\n<div>&amp;</div>\n```', 'code');
      expect(code.textContent, '<div>&amp;</div>\n');
    });

    test('hard line breaks', () {
      expect(tagsOf('one  \ntwo'), contains('br'));
      expect(tagsOf('one\\\ntwo'), contains('br'));
      expect(tagsOf('one<br>two'), contains('br'));
    });

    test('soft line breaks stay as newlines in text', () {
      final p = nodesOf('one\ntwo').single as md.Element;
      expect(tagsOf('one\ntwo'), isNot(contains('br')));
      expect(p.textContent, 'one\ntwo');
    });
  });

  group('blocks', () {
    test('headings h1-h6', () {
      expect(tagsOf('# a\n## b\n### c\n#### d\n##### e\n###### f'), <String>[
        'h1',
        'h2',
        'h3',
        'h4',
        'h5',
        'h6',
      ]);
      expect(tagsOf('Title\n====='), <String>['h1']);
    });

    test('nested lists and ordered start', () {
      const source = '3. one\n4. two\n   - nested\n     - deeper\n';
      final ol = nodesOf(source).single as md.Element;
      expect(ol.tag, 'ol');
      expect(ol.attributes['start'], '3');
      expect(tagsOf(source).where((t) => t == 'ul').length, 2);
    });

    test('loose list with blank lines stays a single list', () {
      final nodes = nodesOf('- a\n\n- b\n\n- c\n');
      expect(nodes, hasLength(1));
      expect((nodes.single as md.Element).children, hasLength(3));
    });

    test('task lists', () {
      final inputs = elementsOf(nodesOf('- [ ] todo\n- [x] done'))
          .where((e) => e.tag == 'input')
          .toList();
      expect(inputs, hasLength(2));
      expect(inputs[0].attributes['checked'], isNull);
      expect(inputs[1].attributes['checked'], 'true');
    });

    test('nested blockquotes', () {
      expect(tagsOf('> outer\n>> inner'), <String>[
        'blockquote',
        'p',
        'blockquote',
        'p',
      ]);
    });

    test('fenced and indented code blocks', () {
      final fenced = firstTag('```dart\nvoid main() {}\n```', 'code');
      expect(fenced.attributes['class'], 'language-dart');
      expect(fenced.textContent, 'void main() {}\n');

      final indented = firstTag('para\n\n    indented code\n', 'code');
      expect(indented.textContent, 'indented code\n');
    });

    test('fenced code keeps blank lines in one block', () {
      final doc = MarkdownDocument.parse('```\na\n\n\nb\n```\n\nafter');
      expect(doc.blocks, hasLength(2));
      expect(firstTag('```\na\n\n\nb\n```', 'code').textContent, 'a\n\n\nb\n');
    });

    test('tables with alignment', () {
      const source = '| L | C | R |\n|:--|:-:|--:|\n| 1 | 2 | 3 |';
      final cells = elementsOf(nodesOf(source))
          .where((e) => e.tag == 'th' || e.tag == 'td')
          .toList();
      expect(cells, hasLength(6));
      expect(cells.take(3).map((c) => c.attributes['align']), <String>[
        'left',
        'center',
        'right',
      ]);
      expect(cells.last.textContent, '3');
    });

    test('horizontal rules', () {
      expect(tagsOf('a\n\n---\n\nb'), <String>['p', 'hr', 'p']);
      expect(tagsOf('***'), <String>['hr']);
    });

    test('images', () {
      final img = firstTag('![alt text](https://x.dev/a.png)', 'img');
      expect(img.attributes['src'], 'https://x.dev/a.png');
      expect(img.attributes['alt'], 'alt text');
    });

    test('footnotes', () {
      final doc = MarkdownDocument.parse(
        'See this[^n] and that[^2].\n\n[^2]: Second.\n[^n]: First note.\n',
      );
      final refs = elementsOf(doc.blocks.expand((b) => b.nodes).toList())
          .where((e) => e.tag == 'sup')
          .map((e) => e.textContent)
          .toList();
      expect(refs, <String>['1', '2']);
      expect(doc.footnotes.map((f) => f.label), <String>['n', '2']);
      expect(doc.footnotes.map((f) => f.number), <int>[1, 2]);
      expect(html(doc.footnotes.first.nodes), contains('First note.'));
    });

    test('link reference definitions resolve across blocks', () {
      final a = firstTag('[docs][ref]\n\n[ref]: https://ref.dev', 'a');
      expect(a.attributes['href'], 'https://ref.dev');
    });
  });

  group('math', () {
    md.Element mathOf(String source) => firstTag(source, 'math');
    List<md.Element> allMath(String source) =>
        elementsOf(nodesOf(source)).where((e) => e.tag == 'math').toList();

    test('inline dollar math', () {
      final m = mathOf(r'Energy $E = mc^2$ here');
      expect(m.textContent, 'E = mc^2');
      expect(m.attributes['display'], 'false');
    });

    test('inline paren math', () {
      final m = mathOf(r'where \(a^2 + b^2\) holds');
      expect(m.textContent, 'a^2 + b^2');
      expect(m.attributes['display'], 'false');
    });

    test('inline bracket and double-dollar display math', () {
      expect(mathOf(r'so \[x+1\] ok').attributes['display'], 'true');
      expect(mathOf(r'so $$x+1$$ ok').attributes['display'], 'true');
    });

    test('display math blocks span lines', () {
      final block = firstTag(
        'Before\n\$\$\na = b\n\nc = d\n\$\$\nafter',
        'math-block',
      );
      expect(block.textContent, 'a = b\n\nc = d');
      final bracket = firstTag('\\[\n\\int_0^1 x\\,dx\n\\]', 'math-block');
      expect(bracket.textContent, r'\int_0^1 x\,dx');
      final single = firstTag(r'$$ x^2 $$', 'math-block');
      expect(single.textContent, 'x^2');
    });

    test('display math inside a list item', () {
      expect(
        tagsOf('1. Formula:\n   \$\$\n   x\n   \$\$\n'),
        contains('math-block'),
      );
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

    test('math and typst fences keep their language', () {
      expect(
        firstTag('```math\nx^2\n```', 'code').attributes['class'],
        'language-math',
      );
      expect(
        firstTag('```typst\n#set page()\n```', 'code').attributes['class'],
        'language-typst',
      );
    });

    group('currency is not math', () {
      test(r'$5 and $10', () {
        expect(allMath(r'It costs $5 and $10 later.'), isEmpty);
      });
      test('space after opening dollar', () {
        expect(allMath(r'between $ 5 and 6$ ok'), isEmpty);
      });
      test('space before closing dollar', () {
        expect(allMath(r'between $5 and 6 $ ok'), isEmpty);
      });
      test('digit right after closing dollar', () {
        expect(allMath(r'from $a$5'), isEmpty);
      });
      test('escaped dollars', () {
        expect(allMath(r'price \$x\$ here'), isEmpty);
      });
      test('currency next to real math', () {
        final math = allMath(r'Pay $5, then solve $x+1$ for $10.');
        expect(math.map((m) => m.textContent), <String>['x+1']);
      });
      test('dollar inside inline code', () {
        expect(allMath(r'run `echo $HOME$` now'), isEmpty);
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

    test('re-parses the previous block too while the last line is partial', () {
      // `1` may still become `1. item`, which would join the list above.
      final previous = MarkdownDocument.parse('Intro\n\n- a\n\n1');
      final next = MarkdownDocument.appendParse(
        previous,
        '${previous.source}. b',
      );
      expect(identical(next.blocks[0], previous.blocks[0]), isTrue);
      expect(identical(next.blocks[1], previous.blocks[1]), isFalse);
      expect(next.blocks, hasLength(2));
    });

    test('falls back to a full parse when not an append', () {
      final previous = MarkdownDocument.parse('a\n\nb');
      final next = MarkdownDocument.appendParse(previous, 'x\n\nb');
      expect(next.isIncremental, isFalse);
      expect(identical(next.blocks.first, previous.blocks.first), isFalse);
    });

    test('identical data returns the same document', () {
      final previous = MarkdownDocument.parse('a\n\nb');
      expect(MarkdownDocument.appendParse(previous, 'a\n\nb'), same(previous));
    });

    test('unterminated fence is an open code block until closed', () {
      var doc = MarkdownDocument.parse('Intro\n\n```python\nprint(1)\n');
      expect(doc.blocks.last.isOpen, isTrue);
      expect(html(doc.blocks.last.nodes), contains('print(1)'));
      doc = MarkdownDocument.appendParse(doc, '${doc.source}```\n\nDone');
      expect(doc.blocks.map((b) => b.isOpen), everyElement(isFalse));
      expect(doc.blocks, hasLength(3));
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
        final incrementalHtml = html(
          doc.blocks.expand((b) => b.nodes).toList(),
        );
        final fullHtml = html(full.blocks.expand((b) => b.nodes).toList());
        expect(incrementalHtml, fullHtml, reason: 'prefix length $i');
      }
      expect(doc.blocks.length, greaterThan(10));
    });
  });
}
