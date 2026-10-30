import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:markdown/markdown.dart' as md;

import '../code/code_block_view.dart';
import '../parser/document.dart';
import '../style.dart';
import '../syntax/math_syntax.dart';
import 'inline_builder.dart';
import 'link_text.dart';
import 'math.dart';

/// Everything that affects how a block renders. Compared by value so that
/// unchanged blocks can reuse their previously built widgets.
@immutable
class RenderConfig {
  const RenderConfig({
    required this.style,
    required this.mathBuilder,
    required this.codeBlockBuilder,
    required this.linksEnabled,
    required this.preserveSoftBreaks,
  });

  final MarkdownStyle style;
  final MathBuilder mathBuilder;
  final CodeBlockBuilder codeBlockBuilder;
  final bool linksEnabled;
  final bool preserveSoftBreaks;

  @override
  bool operator ==(Object other) =>
      other is RenderConfig &&
      other.style == style &&
      other.mathBuilder == mathBuilder &&
      other.codeBlockBuilder == codeBlockBuilder &&
      other.linksEnabled == linksEnabled &&
      other.preserveSoftBreaks == preserveSoftBreaks;

  @override
  int get hashCode => Object.hash(style, mathBuilder, codeBlockBuilder, linksEnabled, preserveSoftBreaks);
}

/// Languages whose fenced blocks render as display math.
const Set<String> kMathFenceLanguages = <String>{'math', 'latex', 'tex', 'katex'};

const Set<String> _blockTags = <String>{
  'p',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'pre',
  'blockquote',
  'ul',
  'ol',
  'li',
  'table',
  'hr',
  'div',
  'section',
  kMathBlockTag,
};

const List<String> _bullets = <String>['•', '◦', '▪'];
const String _checkboxEmpty = '☐';
const String _checkboxChecked = '☑';

/// Converts block-level markdown AST nodes into widgets.
class BlockBuilder {
  BlockBuilder({required this.context, required this.config, required this.onTapLink, this.openCodeBlock});

  final BuildContext context;
  final RenderConfig config;
  final ValueChanged<String> onTapLink;

  /// The `pre` element of a fence that has not been closed yet (streaming);
  /// it always renders as a code block, even for ```math.
  final md.Element? openCodeBlock;

  MarkdownStyle get style => config.style;

  /// Builds [nodes] as a vertical stack of blocks.
  Widget build(List<md.Node> nodes, {TextStyle? base}) {
    return _column(_blocks(nodes, base ?? style.body), style.blockSpacing);
  }

  /// Builds the footnote definitions section.
  Widget buildFootnotes(List<MarkdownFootnote> footnotes) {
    final small = style.body.copyWith(fontSize: (style.body.fontSize ?? 15) * 0.85);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: <Widget>[
        _rule(),
        for (final note in footnotes) _markerRow('${note.number}.', small, _column(_blocks(note.nodes, small), 4)),
      ],
    );
  }

  /// Finds the last `pre` element of [nodes] in document order.
  static md.Element? lastCodeBlock(List<md.Node> nodes) {
    for (var i = nodes.length - 1; i >= 0; i--) {
      final node = nodes[i];
      if (node is! md.Element) continue;
      if (node.tag == 'pre') return node;
      final nested = lastCodeBlock(node.children ?? const <md.Node>[]);
      if (nested != null) return nested;
    }
    return null;
  }

  List<Widget> _blocks(List<md.Node> nodes, TextStyle base, [int depth = 0]) {
    final out = <Widget>[];
    final run = <md.Node>[];
    void flush() {
      if (run.isEmpty) return;
      final paragraph = _paragraph(List.of(run), base);
      if (paragraph != null) out.add(paragraph);
      run.clear();
    }

    for (final node in nodes) {
      if (MarkdownDocument.isFootnoteDefinition(node)) continue;
      if (node is md.Element && _blockTags.contains(node.tag)) {
        flush();
        final widget = _block(node, base, depth);
        if (widget != null) out.add(widget);
      } else {
        run.add(node);
      }
    }
    flush();
    return out;
  }

  Widget? _block(md.Element element, TextStyle base, int depth) {
    final children = element.children ?? const <md.Node>[];
    switch (element.tag) {
      case 'p':
        final isAlertTitle = element.attributes['class'] == 'markdown-alert-title';
        return _paragraph(children, isAlertTitle ? base.copyWith(fontWeight: FontWeight.w600) : base);
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        final level = int.parse(element.tag.substring(1));
        return Semantics(header: true, child: _paragraph(children, style.heading(level)) ?? const SizedBox.shrink());
      case 'pre':
        return _codeBlock(element, base);
      case 'blockquote' || 'div':
        return _quote(children, base.merge(style.blockquote), depth);
      case 'ul' || 'ol':
        return _list(element, base, depth);
      case 'table':
        return _table(element);
      case 'hr':
        return _rule();
      case kMathBlockTag:
        return _displayMath(element.textContent, base);
      default:
        final blocks = _blocks(children, base, depth);
        return blocks.isEmpty ? null : _column(blocks, style.blockSpacing);
    }
  }

  Widget? _paragraph(List<md.Node> nodes, TextStyle textStyle, {TextAlign? textAlign}) {
    // A paragraph holding only display math renders as a display block.
    final meaningful = nodes.where((n) => !(n is md.Text && n.text.trim().isEmpty)).toList(growable: false);
    if (meaningful.length == 1) {
      final only = meaningful.single;
      if (only is md.Element && only.tag == kMathTag && only.attributes[kDisplayAttribute] == 'true') {
        return _displayMath(only.textContent, textStyle);
      }
    }

    final inline = InlineBuilder(
      context: context,
      style: style,
      mathBuilder: config.mathBuilder,
      preserveSoftBreaks: config.preserveSoftBreaks,
    );
    final span = inline.build(nodes, textStyle);
    if (span.children == null || span.children!.isEmpty) return null;
    if (inline.hasLinks && config.linksEnabled) {
      return LinkAwareText(span: span, onTapLink: onTapLink, textAlign: textAlign);
    }
    return Text.rich(span, textAlign: textAlign);
  }

  Widget _codeBlock(md.Element pre, TextStyle base) {
    md.Element? code;
    for (final child in pre.children ?? const <md.Node>[]) {
      if (child is md.Element && child.tag == 'code') {
        code = child;
        break;
      }
    }
    var text = (code ?? pre).textContent;
    if (text.endsWith('\n')) text = text.substring(0, text.length - 1);
    final cls = code?.attributes['class'];
    final language = cls != null && cls.startsWith('language-') ? cls.substring('language-'.length) : null;
    final isOpen = identical(pre, openCodeBlock);
    if (!isOpen && language != null && kMathFenceLanguages.contains(language.toLowerCase())) {
      return _displayMath(text.trim(), base);
    }
    return config.codeBlockBuilder(context, text, language);
  }

  Widget _displayMath(String tex, TextStyle base) {
    return Align(
      alignment: Alignment.center,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: DefaultTextStyle.merge(style: base, child: config.mathBuilder(context, tex, display: true)),
        ),
      ),
    );
  }

  Widget _quote(List<md.Node> children, TextStyle quoteStyle, int depth) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: style.blockquoteBar, width: 3)),
      ),
      child: Padding(
        padding: const EdgeInsets.only(left: 12, top: 2, bottom: 2),
        child: _column(_blocks(children, quoteStyle, depth), style.blockSpacing * 0.75),
      ),
    );
  }

  Widget _list(md.Element list, TextStyle base, int depth) {
    final ordered = list.tag == 'ol';
    var number = int.tryParse(list.attributes['start'] ?? '') ?? 1;
    final items = <md.Element>[
      for (final child in list.children ?? const <md.Node>[])
        if (child is md.Element && child.tag == 'li') child,
    ];
    final loose = items.any((li) => (li.children ?? const <md.Node>[]).any((c) => c is md.Element && c.tag == 'p'));
    final itemSpacing = loose ? style.blockSpacing * 0.5 : 4.0;

    final rows = <Widget>[];
    for (final li in items) {
      final checked = _taskState(li);
      final String marker;
      if (checked != null) {
        marker = checked ? _checkboxChecked : _checkboxEmpty;
      } else if (ordered) {
        marker = '$number.';
      } else {
        marker = _bullets[depth % _bullets.length];
      }
      number++;
      final content = _blocks(li.children ?? const <md.Node>[], base, depth + 1);
      rows.add(_markerRow(marker, base, _column(content, itemSpacing)));
    }
    return _column(rows, itemSpacing);
  }

  /// `true`/`false` for task-list items, `null` for regular items.
  static bool? _taskState(md.Element li) {
    final children = li.children;
    if (children == null || children.isEmpty) return null;
    var first = children.first;
    if (first is md.Element && first.tag == 'p') {
      final pChildren = first.children;
      if (pChildren == null || pChildren.isEmpty) return null;
      first = pChildren.first;
    }
    if (first is md.Element && first.tag == 'input' && first.attributes['type'] == 'checkbox') {
      return first.attributes['checked'] == 'true';
    }
    return null;
  }

  Widget _markerRow(String marker, TextStyle base, Widget content) {
    final fontSize = base.fontSize ?? 15;
    final extraChars = math.max(0, marker.length - 2);
    final width = style.listIndent + extraChars * fontSize * 0.55;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: width,
          child: Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Text(marker, style: base, textAlign: TextAlign.right),
          ),
        ),
        Expanded(child: content),
      ],
    );
  }

  Widget _table(md.Element table) {
    final rows = <({bool header, List<md.Element> cells})>[];
    for (final section in table.children ?? const <md.Node>[]) {
      if (section is! md.Element) continue;
      for (final tr in section.children ?? const <md.Node>[]) {
        if (tr is! md.Element || tr.tag != 'tr') continue;
        final cells = <md.Element>[
          for (final cell in tr.children ?? const <md.Node>[])
            if (cell is md.Element) cell,
        ];
        rows.add((header: cells.isNotEmpty && cells.first.tag == 'th', cells: cells));
      }
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    final columns = rows.map((r) => r.cells.length).reduce(math.max);
    if (columns == 0) return const SizedBox.shrink();

    Widget cell(md.Element? element, bool header) {
      if (element == null) return const SizedBox.shrink();
      final textAlign = switch (element.attributes['align']) {
        'center' => TextAlign.center,
        'right' => TextAlign.end,
        'left' => TextAlign.start,
        _ => TextAlign.start,
      };
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child:
            _paragraph(
              element.children ?? const <md.Node>[],
              header ? style.tableHeader : style.tableCell,
              textAlign: textAlign,
            ) ??
            const SizedBox.shrink(),
      );
    }

    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          defaultColumnWidth: const MinColumnWidth(IntrinsicColumnWidth(), FixedColumnWidth(360)),
          border: TableBorder.all(color: style.tableBorder),
          defaultVerticalAlignment: TableCellVerticalAlignment.top,
          children: <TableRow>[
            for (final row in rows)
              TableRow(
                decoration: row.header ? BoxDecoration(color: style.codeBlockBackground) : null,
                children: <Widget>[
                  for (var i = 0; i < columns; i++) cell(i < row.cells.length ? row.cells[i] : null, row.header),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _rule() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: SizedBox(height: 1, child: ColoredBox(color: style.ruleColor)),
    );
  }

  static Widget _column(List<Widget> children, double spacing) {
    if (children.isEmpty) return const SizedBox.shrink();
    if (children.length == 1) return children.single;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: spacing,
      children: children,
    );
  }
}
