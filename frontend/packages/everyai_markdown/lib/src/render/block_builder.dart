import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:markdown/markdown.dart' as md;

import '../code/code_block_view.dart';
import '../parser/document.dart';
import '../style.dart';
import '../syntax/math_syntax.dart';
import 'chips.dart';
import 'inline_builder.dart';
import 'link_text.dart';
import 'math.dart';
import 'scroll.dart';

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
    this.citationBuilder = defaultCitationBuilder,
    this.citationsEnabled = false,
  });

  final MarkdownStyle style;
  final MathBuilder mathBuilder;
  final CodeBlockBuilder codeBlockBuilder;
  final bool linksEnabled;
  final bool preserveSoftBreaks;
  final CitationBuilder citationBuilder;

  /// Whether citation chips are tappable.
  final bool citationsEnabled;

  @override
  bool operator ==(Object other) =>
      other is RenderConfig &&
      other.style == style &&
      other.mathBuilder == mathBuilder &&
      other.codeBlockBuilder == codeBlockBuilder &&
      other.linksEnabled == linksEnabled &&
      other.preserveSoftBreaks == preserveSoftBreaks &&
      other.citationBuilder == citationBuilder &&
      other.citationsEnabled == citationsEnabled;

  @override
  int get hashCode => Object.hash(
    style,
    mathBuilder,
    codeBlockBuilder,
    linksEnabled,
    preserveSoftBreaks,
    citationBuilder,
    citationsEnabled,
  );
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

/// A built block plus its heading level (0 for non-headings), used to space
/// headings: more room above than below.
typedef _Built = ({Widget widget, int heading});
const String _checkboxEmpty = '☐';
const String _checkboxChecked = '☑';

/// Converts block-level markdown AST nodes into widgets.
class BlockBuilder {
  BlockBuilder({
    required this.context,
    required this.config,
    required this.onTapLink,
    this.onTapCitation,
    this.openCodeBlock,
  });

  final BuildContext context;
  final RenderConfig config;
  final ValueChanged<String> onTapLink;
  final ValueChanged<int>? onTapCitation;

  /// The `pre` element of a fence that has not been closed yet (streaming);
  /// it always renders as a code block, even for ```math.
  final md.Element? openCodeBlock;

  MarkdownStyle get style => config.style;

  /// Builds [nodes] as a vertical stack of blocks.
  Widget build(List<md.Node> nodes, {TextStyle? base}) {
    return _column(_blocks(nodes, base ?? style.body), style.blockSpacing);
  }

  /// The heading level (1-6) of [node], or 0 if it is not a heading.
  static int headingLevel(md.Node? node) {
    if (node is! md.Element) return 0;
    final tag = node.tag;
    if (tag.length == 2 && tag.codeUnitAt(0) == 0x68 /* h */ ) {
      final level = tag.codeUnitAt(1) - 0x30;
      if (level >= 1 && level <= 6) return level;
    }
    return 0;
  }

  /// The vertical gap between two blocks: extra room above a heading
  /// (scaled by its level), less below one.
  static double gapBetween(int previousHeading, int nextHeading, double spacing) {
    if (nextHeading > 0) {
      const extra = <double>[1.0, 0.8, 0.55, 0.35, 0.25, 0.25];
      return spacing * (1 + extra[nextHeading - 1]);
    }
    if (previousHeading > 0) return spacing * 0.55;
    return spacing;
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
        for (final note in footnotes)
          _markerRow('${note.number}.', small, _column(_blocks(note.nodes, small), 4), _markerWidth(small, 3)),
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

  List<_Built> _blocks(List<md.Node> nodes, TextStyle base, [int depth = 0]) {
    final out = <_Built>[];
    final run = <md.Node>[];
    void flush() {
      if (run.isEmpty) return;
      final paragraph = _paragraph(List.of(run), base);
      if (paragraph != null) out.add((widget: paragraph, heading: 0));
      run.clear();
    }

    for (final node in nodes) {
      if (MarkdownDocument.isFootnoteDefinition(node)) continue;
      if (node is md.Element && _blockTags.contains(node.tag)) {
        flush();
        final widget = _block(node, base, depth);
        if (widget != null) out.add((widget: widget, heading: headingLevel(node)));
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
      citationBuilder: config.citationBuilder,
      onTapCitation: config.citationsEnabled ? onTapCitation : null,
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
    return CustomPaint(
      painter: _QuoteBarPainter(style.blockquoteBar),
      child: Padding(
        padding: const EdgeInsets.only(left: 15, top: 2, bottom: 2),
        child: _column(_blocks(children, quoteStyle, depth), style.blockSpacing * 0.75),
      ),
    );
  }

  Widget _list(md.Element list, TextStyle base, int depth) {
    final ordered = list.tag == 'ol';
    final start = int.tryParse(list.attributes['start'] ?? '') ?? 1;
    final items = <md.Element>[
      for (final child in list.children ?? const <md.Node>[])
        if (child is md.Element && child.tag == 'li') child,
    ];
    final loose = items.any((li) => (li.children ?? const <md.Node>[]).any((c) => c is md.Element && c.tag == 'p'));
    final itemSpacing = loose ? style.blockSpacing * 0.5 : 4.0;

    final markers = <String>[];
    for (var i = 0; i < items.length; i++) {
      final checked = _taskState(items[i]);
      if (checked != null) {
        markers.add(checked ? _checkboxChecked : _checkboxEmpty);
      } else if (ordered) {
        markers.add('${start + i}.');
      } else {
        markers.add(_bullets[depth % _bullets.length]);
      }
    }
    // One marker column per list, sized for its widest marker, so that
    // `9.` and `10.` line up on the dot.
    final width = _markerWidth(base, markers.fold(0, (w, m) => math.max(w, m.length)));
    final markerStyle = ordered
        ? base.copyWith(fontFeatures: const <FontFeature>[FontFeature.tabularFigures()])
        : base.copyWith(color: base.color?.withValues(alpha: 0.8));

    final rows = <_Built>[];
    for (var i = 0; i < items.length; i++) {
      final content = _blocks(items[i].children ?? const <md.Node>[], base, depth + 1);
      rows.add((widget: _markerRow(markers[i], markerStyle, _column(content, itemSpacing), width), heading: 0));
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

  double _markerWidth(TextStyle base, int markerLength) {
    final fontSize = base.fontSize ?? 15;
    return style.listIndent + math.max(0, markerLength - 2) * fontSize * 0.6;
  }

  Widget _markerRow(String marker, TextStyle markerStyle, Widget content, double width) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: width,
          child: Padding(
            padding: const EdgeInsets.only(right: 7),
            child: Text(marker, style: markerStyle, textAlign: TextAlign.right),
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
      final textStyle = header
          ? style.tableHeader.copyWith(fontWeight: style.tableHeader.fontWeight ?? FontWeight.w600)
          : style.tableCell;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child:
            _paragraph(element.children ?? const <md.Node>[], textStyle, textAlign: textAlign) ??
            const SizedBox.shrink(),
      );
    }

    final radius = BorderRadius.circular(math.min(style.codeBlockRadius, 10));
    final side = BorderSide(color: style.tableBorder);
    var bodyRow = 0;
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: HorizontalScroller(
        thumbColor: (style.body.color ?? const Color(0xFF888888)).withValues(alpha: 0.25),
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(border: Border.fromBorderSide(side), borderRadius: radius),
          child: ClipRRect(
            borderRadius: radius,
            child: Table(
              defaultColumnWidth: const MinColumnWidth(IntrinsicColumnWidth(), FixedColumnWidth(360)),
              border: TableBorder(horizontalInside: side, verticalInside: side),
              defaultVerticalAlignment: TableCellVerticalAlignment.top,
              children: <TableRow>[
                for (final row in rows)
                  TableRow(
                    decoration: row.header
                        ? BoxDecoration(color: style.tableHeaderBackground)
                        : (bodyRow++).isOdd
                        ? BoxDecoration(color: style.tableStripe)
                        : null,
                    children: <Widget>[
                      for (var i = 0; i < columns; i++) cell(i < row.cells.length ? row.cells[i] : null, row.header),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _rule() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: SizedBox(height: 1, child: ColoredBox(color: style.ruleColor)),
    );
  }

  static Widget _column(List<_Built> children, double spacing) {
    if (children.isEmpty) return const SizedBox.shrink();
    if (children.length == 1) return children.single.widget;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (var i = 0; i < children.length; i++) ...<Widget>[
          if (i > 0) SizedBox(height: gapBetween(children[i - 1].heading, children[i].heading, spacing)),
          children[i].widget,
        ],
      ],
    );
  }
}

/// Paints a block quote's 3px rounded accent bar along the left edge.
class _QuoteBarPainter extends CustomPainter {
  const _QuoteBarPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(RRect.fromLTRBR(0, 0, 3, size.height, const Radius.circular(1.5)), Paint()..color = color);
  }

  @override
  bool shouldRepaint(_QuoteBarPainter oldDelegate) => oldDelegate.color != color;
}
