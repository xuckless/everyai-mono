import 'package:markdown/markdown.dart' as md;

/// Tag used for math nodes in the AST, both inline and display.
const String kMathTag = 'math';

/// Tag used for display math blocks produced by [MathBlockSyntax].
const String kMathBlockTag = 'math-block';

/// Attribute set to `'true'` on display math nodes.
const String kDisplayAttribute = 'display';

md.Element _mathElement(String tag, String tex, {required bool display}) {
  return md.Element.text(tag, tex)..attributes[kDisplayAttribute] = display ? 'true' : 'false';
}

/// Display math blocks: `$$ ... $$` and `\[ ... \]`, possibly spanning lines.
///
/// An unterminated block (no closing delimiter before the end of input, as
/// happens while an LLM is still streaming) is emitted as a plain-text
/// paragraph so the raw source stays visible until the closer arrives.
class MathBlockSyntax extends md.BlockSyntax {
  const MathBlockSyntax();

  static final RegExp _pattern = RegExp(r'^ {0,3}(\$\$|\\\[)(.*)$');

  @override
  RegExp get pattern => _pattern;

  static String _closerFor(String opener) => opener == r'$$' ? r'$$' : r'\]';

  @override
  bool canParse(md.BlockParser parser) {
    final match = _pattern.firstMatch(parser.current.content);
    if (match == null) return false;
    final closer = _closerFor(match[1]!);
    final rest = match[2]!.trimRight();
    // `$$a$$ and $$b$$` is a paragraph with inline display math, not a block.
    final closerIndex = rest.indexOf(closer);
    return closerIndex == -1 || closerIndex == rest.length - closer.length;
  }

  @override
  md.Node parse(md.BlockParser parser) {
    final first = parser.current.content;
    final match = _pattern.firstMatch(first)!;
    final closer = _closerFor(match[1]!);
    final rest = match[2]!.trimRight();
    parser.advance();

    if (rest.endsWith(closer) && rest.length > closer.length - 1) {
      final tex = rest.substring(0, rest.length - closer.length).trim();
      return _mathElement(kMathBlockTag, tex, display: true);
    }

    final raw = <String>[first];
    final body = <String>[rest];
    while (!parser.isDone) {
      final line = parser.current.content;
      raw.add(line);
      parser.advance();
      final trimmed = line.trimRight();
      if (trimmed.endsWith(closer)) {
        body.add(trimmed.substring(0, trimmed.length - closer.length));
        return _mathElement(kMathBlockTag, body.join('\n').trim(), display: true);
      }
      body.add(line);
    }
    // Unterminated: render the raw source as plain text until it is closed.
    return md.Element('p', <md.Node>[
      for (var i = 0; i < raw.length; i++) ...<md.Node>[if (i > 0) md.Element.empty('br'), md.Text(raw[i])],
    ]);
  }
}

/// Inline display math written as `$$...$$` inside a paragraph.
class DollarDisplayMathSyntax extends md.InlineSyntax {
  DollarDisplayMathSyntax() : super(r'\$\$((?:\\[\s\S]|[^\\$])+?)\$\$', startCharacter: 0x24);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(_mathElement(kMathTag, match[1]!.trim(), display: true));
    return true;
  }
}

/// Inline math written as `$...$`.
///
/// To avoid treating currency as math (`$5 and $10`), the opening `$` must be
/// followed by a non-space, the closing `$` must be preceded by a non-space,
/// and the closing `$` must not be followed by a digit.
class DollarInlineMathSyntax extends md.InlineSyntax {
  DollarInlineMathSyntax() : super(r'\$(?![\s$])((?:\\.|[^\\$\n])*?[^\s\\$])\$(?!\d)', startCharacter: 0x24);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(_mathElement(kMathTag, match[1]!, display: false));
    return true;
  }
}

/// Inline math written as `\(...\)`.
class ParenInlineMathSyntax extends md.InlineSyntax {
  ParenInlineMathSyntax() : super(r'\\\(([\s\S]+?)\\\)', startCharacter: 0x5C);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(_mathElement(kMathTag, match[1]!.trim(), display: false));
    return true;
  }
}

/// Display math written as `\[...\]` inside a paragraph.
class BracketDisplayMathSyntax extends md.InlineSyntax {
  BracketDisplayMathSyntax() : super(r'\\\[([\s\S]+?)\\\]', startCharacter: 0x5C);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(_mathElement(kMathTag, match[1]!.trim(), display: true));
    return true;
  }
}

/// `<br>`, `<br/>` and `<br />` become hard line breaks; LLMs emit these
/// frequently inside table cells.
class HtmlBreakSyntax extends md.InlineSyntax {
  HtmlBreakSyntax() : super(r'<br\s*/?>', startCharacter: 0x3C, caseSensitive: false);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.empty('br'));
    return true;
  }
}
