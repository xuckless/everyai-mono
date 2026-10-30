import 'package:flutter/widgets.dart';
import 'package:markdown/markdown.dart' as md;

import '../style.dart';
import '../syntax/citation_syntax.dart';
import '../syntax/math_syntax.dart';
import 'chips.dart';
import 'image.dart';
import 'link_text.dart';
import 'math.dart';

/// Inline code spans up to this many characters render as a chip; longer
/// ones render as plain highlighted text so they can wrap across lines.
const int kInlineCodeChipMaxLength = 48;

/// Converts inline markdown AST nodes into [InlineSpan]s.
class InlineBuilder {
  InlineBuilder({
    required this.context,
    required this.style,
    required this.mathBuilder,
    required this.preserveSoftBreaks,
    this.citationBuilder = defaultCitationBuilder,
    this.onTapCitation,
  });

  final BuildContext context;
  final MarkdownStyle style;
  final MathBuilder mathBuilder;
  final CitationBuilder citationBuilder;
  final ValueChanged<int>? onTapCitation;

  /// Whether soft line breaks render as newlines instead of spaces.
  final bool preserveSoftBreaks;

  /// Set when any built span is a link.
  bool hasLinks = false;

  /// Identifies the spans of one link element, for hover effects.
  int _linkGroup = 0;
  int _linkCount = 0;

  /// Builds a span tree for [nodes] in [base] style.
  TextSpan build(List<md.Node> nodes, TextStyle base) {
    hasLinks = false;
    final children = <InlineSpan>[];
    for (final node in nodes) {
      _visit(node, base, null, children);
    }
    _trimEdges(children);
    return TextSpan(style: base, children: children);
  }

  void _visit(md.Node node, TextStyle current, String? href, List<InlineSpan> out) {
    if (node is md.Text) {
      final text = preserveSoftBreaks ? node.text : node.text.replaceAll('\n', ' ');
      _addText(text, current, href, out);
      return;
    }
    if (node is md.UnparsedContent) {
      _addText(node.textContent, current, href, out);
      return;
    }
    if (node is! md.Element) return;

    final children = node.children ?? const <md.Node>[];
    void visitChildren(TextStyle style, [String? childHref]) {
      for (final child in children) {
        _visit(child, style, childHref ?? href, out);
      }
    }

    switch (node.tag) {
      case 'strong' || 'b':
        visitChildren(current.copyWith(fontWeight: FontWeight.bold));
      case 'em' || 'i':
        visitChildren(current.copyWith(fontStyle: FontStyle.italic));
      case 'del' || 's':
        visitChildren(
          current.copyWith(
            decoration: TextDecoration.combine(<TextDecoration>[
              if (current.decoration != null) current.decoration!,
              TextDecoration.lineThrough,
            ]),
          ),
        );
      case 'code':
        _addCode(node.textContent, current, href, out);
      case 'a':
        hasLinks = true;
        final outerGroup = _linkGroup;
        _linkGroup = ++_linkCount;
        visitChildren(current.merge(style.link), node.attributes['href'] ?? '');
        _linkGroup = outerGroup;
      case 'br':
        _addText('\n', current, href, out);
      case 'input':
        // Task-list checkbox; rendered as the list marker instead.
        break;
      case 'img':
        out.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: MarkdownImage(src: node.attributes['src'] ?? '', alt: node.attributes['alt'] ?? '', style: style),
          ),
        );
      case kMathTag:
        final display = node.attributes[kDisplayAttribute] == 'true';
        out.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: DefaultTextStyle.merge(
              style: current,
              child: mathBuilder(context, node.textContent, display: display),
            ),
          ),
        );
      case kCitationTag:
        final index = int.tryParse(node.attributes[kCitationIndexAttribute] ?? '');
        if (index == null || href != null) {
          _addText(node.textContent, current, href, out);
          break;
        }
        // Adjacent markers (`[1][3]`) share one span so they never wrap apart.
        final previous = out.isEmpty ? null : out.last;
        final indices = <int>[if (previous is _CitationSpan) ...previous.indices, index];
        if (previous is _CitationSpan) out.removeLast();
        out.add(_citationSpan(indices, current));
      case 'sup' when node.attributes['class'] == 'footnote-ref':
        final number = node.textContent;
        out.add(
          TextSpan(
            text: '[$number]',
            style: current
                .merge(style.link)
                .copyWith(fontSize: (current.fontSize ?? 14) * 0.75, decoration: TextDecoration.none),
          ),
        );
      default:
        visitChildren(current);
    }
  }

  _CitationSpan _citationSpan(List<int> indices, TextStyle current) {
    Widget target(int index) => CitationTarget(
      index: index,
      onTap: onTapCitation,
      child: Builder(builder: (context) => citationBuilder(context, index)),
    );
    return _CitationSpan(
      indices: indices,
      child: DefaultTextStyle.merge(
        style: current,
        child: indices.length == 1
            ? target(indices.single)
            : Row(mainAxisSize: MainAxisSize.min, children: <Widget>[for (final i in indices) target(i)]),
      ),
    );
  }

  /// Inline code: a chip for short spans; text with a background fill for
  /// long ones (so they wrap) and inside links (so taps resolve to the link).
  void _addCode(String code, TextStyle current, String? href, List<InlineSpan> out) {
    if (code.isEmpty) return;
    final codeStyle = _withoutBackground(style.inlineCode);
    final bodySize = style.body.fontSize ?? 15;
    final currentSize = current.fontSize ?? bodySize;
    // Keep the code/text size ratio inside headings and small text.
    final fontSize = (codeStyle.fontSize ?? bodySize * 0.88) * (currentSize / bodySize);
    final textStyle = current.merge(codeStyle).copyWith(fontSize: fontSize);

    if (href != null || code.length > kInlineCodeChipMaxLength || code.contains('\n')) {
      _addText(code, textStyle.copyWith(backgroundColor: style.inlineCodeBackground), href, out);
      return;
    }
    out.add(
      WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: InlineCodeChip(
          code: code,
          // A tighter line height keeps the chip within the text line.
          textStyle: textStyle.copyWith(height: 1.3),
          background: style.inlineCodeBackground,
          border: style.inlineCodeBorder,
        ),
      ),
    );
  }

  static TextStyle _withoutBackground(TextStyle s) {
    if (s.backgroundColor == null && s.background == null) return s;
    return TextStyle(
      inherit: s.inherit,
      color: s.color,
      foreground: s.foreground,
      fontSize: s.fontSize,
      fontWeight: s.fontWeight,
      fontStyle: s.fontStyle,
      letterSpacing: s.letterSpacing,
      wordSpacing: s.wordSpacing,
      textBaseline: s.textBaseline,
      height: s.height,
      leadingDistribution: s.leadingDistribution,
      locale: s.locale,
      shadows: s.shadows,
      fontFeatures: s.fontFeatures,
      fontVariations: s.fontVariations,
      decoration: s.decoration,
      decorationColor: s.decorationColor,
      decorationStyle: s.decorationStyle,
      decorationThickness: s.decorationThickness,
      fontFamily: s.fontFamily,
      fontFamilyFallback: s.fontFamilyFallback,
      overflow: s.overflow,
    );
  }

  void _addText(String text, TextStyle style, String? href, List<InlineSpan> out) {
    if (text.isEmpty) return;
    out.add(
      href != null
          ? LinkTextSpan(text: text, style: style, href: href, group: _linkGroup)
          : TextSpan(text: text, style: style),
    );
  }

  /// Drops leading/trailing whitespace-only text (e.g. the `\n` the list
  /// parser inserts between flattened paragraphs).
  static void _trimEdges(List<InlineSpan> spans) {
    while (spans.isNotEmpty &&
        spans.first is TextSpan &&
        (spans.first as TextSpan).children == null &&
        ((spans.first as TextSpan).text ?? '').trim().isEmpty) {
      spans.removeAt(0);
    }
    while (spans.isNotEmpty &&
        spans.last is TextSpan &&
        (spans.last as TextSpan).children == null &&
        ((spans.last as TextSpan).text ?? '').trim().isEmpty) {
      spans.removeLast();
    }
  }
}

/// One or more adjacent citation markers rendered as a single inline widget.
class _CitationSpan extends WidgetSpan {
  const _CitationSpan({required this.indices, required super.child})
    : super(alignment: PlaceholderAlignment.baseline, baseline: TextBaseline.alphabetic);

  final List<int> indices;
}
