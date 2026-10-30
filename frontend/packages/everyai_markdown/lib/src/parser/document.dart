import 'package:flutter/widgets.dart' show immutable;
import 'package:markdown/markdown.dart' as md;

import '../syntax/citation_syntax.dart';
import '../syntax/math_syntax.dart';
import 'segmenter.dart';

/// One top-level block of a [MarkdownDocument]: a slice of the source that
/// was parsed independently, plus the resulting markdown AST nodes.
///
/// A block usually holds a single top-level node (a paragraph, a list, a code
/// block, ...) but can hold several when they are not separated by a blank
/// line (for example a heading directly followed by a paragraph).
@immutable
class MarkdownBlock {
  const MarkdownBlock({
    required this.start,
    required this.end,
    required this.nodes,
    required this.isOpen,
    required this.firstLineComplete,
  });

  /// Offset of the first character of this block in the document source.
  final int start;

  /// Offset just past the last character of this block (including any
  /// trailing blank lines).
  final int end;

  /// The parsed AST (block and inline content).
  ///
  /// Treat as read-only: blocks are shared between successive documents
  /// while streaming.
  final List<md.Node> nodes;

  /// Whether the block ends inside an unclosed construct (a ``` fence or a
  /// `$$` block) because the source is still being streamed.
  final bool isOpen;

  /// Whether the first source line of this block ended with a newline.
  final bool firstLineComplete;

  /// The source text of this block.
  String sourceIn(MarkdownDocument document) => document.source.substring(start, end);

  @override
  String toString() =>
      'MarkdownBlock($start..$end, ${nodes.length} nodes'
      '${isOpen ? ', open' : ''})';
}

/// A footnote definition collected from the document.
@immutable
class MarkdownFootnote {
  const MarkdownFootnote({required this.label, required this.number, required this.nodes});

  /// The label as written, e.g. `1` or `note` for `[^note]`.
  final String label;

  /// 1-based display number, matching the number shown at the reference.
  final int number;

  /// The definition content (block nodes).
  final List<md.Node> nodes;
}

/// A parsed, cacheable Markdown document.
///
/// Build one with [MarkdownDocument.parse], or, while streaming, derive the
/// next one from the previous with [MarkdownDocument.appendParse], which
/// reuses every top-level block except the last.
@immutable
class MarkdownDocument {
  MarkdownDocument._({
    required this.source,
    required List<MarkdownBlock> blocks,
    required Map<String, md.LinkReference> linkReferences,
    required List<String> footnoteLabels,
    required Set<String> footnoteDefinitions,
    required this.isIncremental,
  }) : blocks = List.unmodifiable(blocks),
       linkReferences = Map.unmodifiable(linkReferences),
       footnoteLabels = List.unmodifiable(footnoteLabels),
       footnoteDefinitions = Set.unmodifiable(footnoteDefinitions);

  /// An empty document.
  static final MarkdownDocument empty = MarkdownDocument.parse('');

  /// The full source text.
  final String source;

  /// The top-level blocks, in source order.
  final List<MarkdownBlock> blocks;

  /// Link reference definitions (`[label]: url`) found so far.
  final Map<String, md.LinkReference> linkReferences;

  /// Footnote labels (lower-cased) in order of first reference.
  final List<String> footnoteLabels;

  /// Labels of footnote definitions found so far.
  final Set<String> footnoteDefinitions;

  /// Whether this document was produced by [appendParse] reusing blocks.
  ///
  /// Cross-block references (a link reference or footnote defined after the
  /// block that uses it) can only be resolved by a full [parse]; renderers
  /// typically re-parse once when streaming finishes.
  final bool isIncremental;

  /// Parses [source] from scratch.
  static MarkdownDocument parse(String source) {
    final ctx = _ParseContext.fresh();
    final blocks = ctx.parseFrom(source, 0);
    return ctx.toDocument(source, blocks, isIncremental: false);
  }

  /// Parses [newData], reusing blocks from [previous] when [newData] is an
  /// append to `previous.source`.
  ///
  /// Every top-level block of [previous] except the last is reused as-is (the
  /// identical [MarkdownBlock] objects), and only the tail starting at the
  /// last block is re-parsed. One exception: when the previous block is a
  /// list and the last block's first line was still incomplete, both are
  /// re-parsed, because the partial line may turn out to be another item of
  /// that list (`1` becoming `1. item`).
  ///
  /// Falls back to [parse] when [newData] does not start with
  /// `previous.source`.
  static MarkdownDocument appendParse(MarkdownDocument previous, String newData) {
    if (!newData.startsWith(previous.source)) return parse(newData);
    if (newData.length == previous.source.length) return previous;
    if (previous.blocks.isEmpty) return parse(newData);

    var keep = previous.blocks.length - 1;
    if (keep > 0 &&
        !previous.blocks[keep].firstLineComplete &&
        startsWithListItem(previous.source, previous.blocks[keep - 1].start)) {
      keep--;
    }
    final reparseFrom = previous.blocks[keep].start;

    final ctx = _ParseContext.from(previous);
    final tail = ctx.parseFrom(newData, reparseFrom);
    return ctx.toDocument(newData, [...previous.blocks.take(keep), ...tail], isIncremental: keep > 0);
  }

  /// Footnote definitions, ordered by their reference number.
  late final List<MarkdownFootnote> footnotes = _collectFootnotes();

  List<MarkdownFootnote> _collectFootnotes() {
    final found = <MarkdownFootnote>[];
    var unreferenced = footnoteLabels.length;
    final seen = <String>{};
    for (final block in blocks) {
      for (final node in block.nodes) {
        if (!isFootnoteDefinition(node)) continue;
        final element = node as md.Element;
        final label = element.footnoteLabel!;
        if (!seen.add(label.toLowerCase())) continue;
        final index = footnoteLabels.indexOf(label.toLowerCase());
        found.add(
          MarkdownFootnote(
            label: label,
            number: index >= 0 ? index + 1 : ++unreferenced,
            nodes: element.children ?? const [],
          ),
        );
      }
    }
    found.sort((a, b) => a.number.compareTo(b.number));
    return List.unmodifiable(found);
  }

  /// Whether [node] is a top-level footnote definition.
  static bool isFootnoteDefinition(md.Node node) =>
      node is md.Element && node.tag == 'li' && node.footnoteLabel != null;
}

/// The syntaxes used for every parse.
final List<md.BlockSyntax> _blockSyntaxes = List.unmodifiable(<md.BlockSyntax>[
  const MathBlockSyntax(),
  ...md.ExtensionSet.gitHubWeb.blockSyntaxes,
]);

final List<md.InlineSyntax> _inlineSyntaxes = List.unmodifiable(<md.InlineSyntax>[
  HtmlBreakSyntax(),
  DollarDisplayMathSyntax(),
  DollarInlineMathSyntax(),
  ParenInlineMathSyntax(),
  BracketDisplayMathSyntax(),
  ...md.ExtensionSet.gitHubWeb.inlineSyntaxes.where((s) => s is! md.ColorSwatchSyntax),
  // After the GFM syntaxes so autolinks win; before the built-in link
  // syntax, which only sees what this one declines.
  CitationSyntax(),
]);

/// Holds the cross-block state of a parse (link references, footnotes).
class _ParseContext {
  _ParseContext._(this.document);

  factory _ParseContext.fresh() => _ParseContext._(_newDocument());

  factory _ParseContext.from(MarkdownDocument previous) {
    final document = _newDocument();
    document.linkReferences.addAll(previous.linkReferences);
    for (final label in previous.footnoteDefinitions) {
      document.footnoteReferences[label] = 0;
    }
    document.footnoteLabels.addAll(previous.footnoteLabels);
    return _ParseContext._(document);
  }

  static md.Document _newDocument() => md.Document(
    blockSyntaxes: _blockSyntaxes,
    inlineSyntaxes: _inlineSyntaxes,
    extensionSet: md.ExtensionSet.none,
    encodeHtml: false,
  );

  final md.Document document;

  /// Segments and parses `source[offset..]`. Block structure of every segment
  /// is parsed first so that link references and footnotes defined anywhere
  /// in the range are known before inline parsing (as package:markdown does).
  List<MarkdownBlock> parseFrom(String source, int offset) {
    final segments = segmentSource(source, offset);
    final blockNodes = <List<md.Node>>[];
    for (final segment in segments) {
      final text = source.substring(segment.start, segment.end);
      final lines = text.split('\n').map((l) {
        return md.Line(l.endsWith('\r') ? l.substring(0, l.length - 1) : l);
      }).toList();
      // A trailing newline does not start another line.
      if (lines.length > 1 && lines.last.content.isEmpty) lines.removeLast();
      blockNodes.add(md.BlockParser(lines, document).parseLines());
    }
    final blocks = <MarkdownBlock>[];
    for (var i = 0; i < segments.length; i++) {
      final nodes = blockNodes[i];
      _parseInline(nodes);
      unwrapCitationsInLinks(nodes);
      blocks.add(
        MarkdownBlock(
          start: segments[i].start,
          end: segments[i].end,
          nodes: List.unmodifiable(nodes),
          isOpen: segments[i].unterminated,
          firstLineComplete: segments[i].firstLineComplete,
        ),
      );
    }
    return blocks;
  }

  void _parseInline(List<md.Node> nodes) {
    for (var i = 0; i < nodes.length; i++) {
      final node = nodes[i];
      if (node is md.UnparsedContent) {
        final inline = document.parseInline(node.textContent);
        nodes
          ..removeAt(i)
          ..insertAll(i, inline);
        i += inline.length - 1;
      } else if (node is md.Element && node.children != null) {
        _parseInline(node.children!);
      }
    }
  }

  MarkdownDocument toDocument(String source, List<MarkdownBlock> blocks, {required bool isIncremental}) {
    return MarkdownDocument._(
      source: source,
      blocks: blocks,
      linkReferences: document.linkReferences,
      footnoteLabels: document.footnoteLabels,
      footnoteDefinitions: document.footnoteReferences.keys.toSet(),
      isIncremental: isIncremental,
    );
  }
}
