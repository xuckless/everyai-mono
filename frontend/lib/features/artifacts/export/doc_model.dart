import 'package:flutter/foundation.dart';
import 'package:markdown/markdown.dart' as md;

/// A Markdown document as blocks, for the PDF and Word writers.
sealed class DocBlock {
  const DocBlock();
}

final class HeadingBlock extends DocBlock {
  const HeadingBlock(this.level, this.runs);
  final int level;
  final List<DocRun> runs;
}

final class ParagraphBlock extends DocBlock {
  const ParagraphBlock(this.runs);
  final List<DocRun> runs;
}

final class ListBlock extends DocBlock {
  const ListBlock({required this.ordered, required this.start, required this.items});
  final bool ordered;
  final int start;
  final List<List<DocBlock>> items;
}

final class CodeBlock extends DocBlock {
  const CodeBlock(this.language, this.text);
  final String language;
  final String text;
}

/// A ```svg block (or a raw `<svg>` block).
final class FigureBlock extends DocBlock {
  const FigureBlock(this.svg);
  final String svg;
}

/// A ```mermaid block.
final class DiagramBlock extends DocBlock {
  const DiagramBlock(this.source);
  final String source;
}

/// Display math: `$$…$$` on its own, or a ```math / ```latex block.
final class MathBlock extends DocBlock {
  const MathBlock(this.tex);
  final String tex;
}

final class TableBlock extends DocBlock {
  const TableBlock(this.header, this.rows);
  final List<List<DocRun>> header;
  final List<List<List<DocRun>>> rows;
}

final class QuoteBlock extends DocBlock {
  const QuoteBlock(this.blocks);
  final List<DocBlock> blocks;
}

final class RuleBlock extends DocBlock {
  const RuleBlock();
}

/// A styled piece of text.
@immutable
final class DocRun {
  const DocRun(this.text, {this.bold = false, this.italic = false, this.code = false, this.strike = false, this.link});
  final String text;
  final bool bold;
  final bool italic;
  final bool code;
  final bool strike;
  final String? link;
}

/// Turns raw `<svg>…</svg>` blocks outside code fences into ```svg fences, so
/// one renderer and one exporter handle both ways a model writes figures.
String fenceRawSvg(String markdown) {
  final lines = markdown.split('\n');
  final out = <String>[];
  String? fence;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final trimmed = line.trimLeft();
    if (fence != null) {
      if (trimmed.startsWith(fence)) fence = null;
      out.add(line);
      continue;
    }
    if (RegExp(r'^(`{3,}|~{3,})').firstMatch(trimmed) case final m?) {
      fence = m[1];
      out.add(line);
      continue;
    }
    if (trimmed.startsWith('<svg')) {
      final block = <String>[];
      var j = i;
      for (; j < lines.length; j++) {
        block.add(lines[j]);
        if (lines[j].contains('</svg>')) break;
      }
      if (j < lines.length) {
        out
          ..add('```svg')
          ..addAll(block)
          ..add('```');
        i = j;
        continue;
      }
    }
    out.add(line);
  }
  return out.join('\n');
}

/// The `<svg>` sources of the ```svg blocks in [markdown], in order.
List<String> svgFiguresIn(String markdown) => [
  for (final b in parseDoc(markdown).expand(_flatten))
    if (b is FigureBlock) b.svg,
];

Iterable<DocBlock> _flatten(DocBlock b) sync* {
  yield b;
  switch (b) {
    case ListBlock(:final items):
      for (final item in items) {
        yield* item.expand(_flatten);
      }
    case QuoteBlock(:final blocks):
      yield* blocks.expand(_flatten);
    default:
  }
}

/// Parses GitHub-flavored Markdown into [DocBlock]s.
List<DocBlock> parseDoc(String markdown) {
  final nodes = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  ).parse(fenceRawSvg(markdown).replaceAll('\r\n', '\n'));
  return _blocks(nodes);
}

List<DocBlock> _blocks(List<md.Node> nodes) {
  final out = <DocBlock>[];
  for (final n in nodes) {
    if (n is md.Text) {
      if (n.text.trim().isNotEmpty) out.add(ParagraphBlock([DocRun(_stripTags(n.text).trim())]));
      continue;
    }
    if (n is! md.Element) continue;
    switch (n.tag) {
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        out.add(HeadingBlock(int.parse(n.tag.substring(1)), _runs(n.children)));
      case 'p':
        final text = n.textContent.trim();
        if (text.startsWith(r'$$') && text.endsWith(r'$$') && text.length > 4) {
          out.add(MathBlock(text.substring(2, text.length - 2).trim()));
        } else {
          out.add(ParagraphBlock(_runs(n.children)));
        }
      case 'ul' || 'ol':
        out.add(
          ListBlock(
            ordered: n.tag == 'ol',
            start: int.tryParse(n.attributes['start'] ?? '') ?? 1,
            items: [for (final li in n.children?.whereType<md.Element>() ?? const <md.Element>[]) _listItem(li)],
          ),
        );
      case 'pre':
        final code = n.children?.whereType<md.Element>().firstOrNull;
        final cls = code?.attributes['class'] ?? '';
        final language = cls.startsWith('language-') ? cls.substring(9).toLowerCase() : '';
        var text = (code ?? n).textContent;
        if (text.endsWith('\n')) text = text.substring(0, text.length - 1);
        out.add(switch (language) {
          'svg' when text.contains('</svg>') => FigureBlock(text),
          'mermaid' => DiagramBlock(text),
          'math' || 'latex' || 'tex' => MathBlock(text),
          _ => CodeBlock(language, text),
        });
      case 'blockquote':
        out.add(QuoteBlock(_blocks(n.children ?? const [])));
      case 'hr':
        out.add(const RuleBlock());
      case 'table':
        List<List<DocRun>> cells(md.Element row) => [
          for (final c in row.children?.whereType<md.Element>() ?? const <md.Element>[]) _runs(c.children),
        ];
        final rows = <md.Element>[
          for (final section in n.children?.whereType<md.Element>() ?? const <md.Element>[])
            ...?section.children?.whereType<md.Element>(),
        ];
        if (rows.isEmpty) continue;
        out.add(TableBlock(cells(rows.first), [for (final r in rows.skip(1)) cells(r)]));
      default:
        out.add(ParagraphBlock(_runs(n.children)));
    }
  }
  return out;
}

List<DocBlock> _listItem(md.Element li) {
  final children = li.children ?? const <md.Node>[];
  // A tight item holds inline nodes directly; a loose one holds paragraphs.
  final isBlock = children.any(
    (c) => c is md.Element && const {'p', 'ul', 'ol', 'pre', 'blockquote', 'table', 'h1', 'h2', 'h3'}.contains(c.tag),
  );
  if (!isBlock) return [ParagraphBlock(_runs(children))];
  final blocks = <DocBlock>[];
  final inline = <md.Node>[];
  void flush() {
    if (inline.isNotEmpty) blocks.add(ParagraphBlock(_runs(List.of(inline))));
    inline.clear();
  }

  for (final c in children) {
    if (c is md.Element && const {'p', 'ul', 'ol', 'pre', 'blockquote', 'table', 'h1', 'h2', 'h3'}.contains(c.tag)) {
      flush();
      blocks.addAll(_blocks([c]));
    } else {
      inline.add(c);
    }
  }
  flush();
  return blocks;
}

List<DocRun> _runs(List<md.Node>? nodes, {bool bold = false, bool italic = false, bool strike = false, String? link}) {
  final out = <DocRun>[];
  for (final n in nodes ?? const <md.Node>[]) {
    if (n is md.Text) {
      final text = _stripTags(n.text);
      if (text.isNotEmpty) out.add(DocRun(text, bold: bold, italic: italic, strike: strike, link: link));
      continue;
    }
    if (n is! md.Element) continue;
    switch (n.tag) {
      case 'strong':
        out.addAll(_runs(n.children, bold: true, italic: italic, strike: strike, link: link));
      case 'em':
        out.addAll(_runs(n.children, bold: bold, italic: true, strike: strike, link: link));
      case 'del':
        out.addAll(_runs(n.children, bold: bold, italic: italic, strike: true, link: link));
      case 'a':
        out.addAll(_runs(n.children, bold: bold, italic: italic, strike: strike, link: n.attributes['href']));
      case 'code':
        out.add(DocRun(n.textContent, code: true, bold: bold, italic: italic, link: link));
      case 'br':
        out.add(const DocRun('\n'));
      case 'img':
        final alt = n.attributes['alt'] ?? '';
        out.add(DocRun('[${alt.isEmpty ? 'image' : alt}]', italic: true));
      case 'input':
        out.add(DocRun(n.attributes['checked'] != null ? '☑ ' : '☐ '));
      default:
        out.addAll(_runs(n.children, bold: bold, italic: italic, strike: strike, link: link));
    }
  }
  return out;
}

/// Inline HTML the parser passes through (`<br>`, `<sup>`…) as plain text.
String _stripTags(String text) => text
    .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
    .replaceAll(RegExp(r'</?[a-zA-Z][^>]*>'), '')
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'");
