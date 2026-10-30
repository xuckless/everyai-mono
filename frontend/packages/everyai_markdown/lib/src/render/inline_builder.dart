import 'package:flutter/widgets.dart';
import 'package:markdown/markdown.dart' as md;

import '../style.dart';
import '../syntax/math_syntax.dart';
import 'image.dart';
import 'link_text.dart';
import 'math.dart';

/// Converts inline markdown AST nodes into [InlineSpan]s.
class InlineBuilder {
  InlineBuilder({
    required this.context,
    required this.style,
    required this.mathBuilder,
    required this.preserveSoftBreaks,
  });

  final BuildContext context;
  final MarkdownStyle style;
  final MathBuilder mathBuilder;

  /// Whether soft line breaks render as newlines instead of spaces.
  final bool preserveSoftBreaks;

  /// Set when any built span is a link.
  bool hasLinks = false;

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
        _addText(node.textContent, current.merge(style.inlineCode), href, out);
      case 'a':
        hasLinks = true;
        visitChildren(current.merge(style.link), node.attributes['href'] ?? '');
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

  void _addText(String text, TextStyle style, String? href, List<InlineSpan> out) {
    if (text.isEmpty) return;
    out.add(href != null ? LinkTextSpan(text: text, style: style, href: href) : TextSpan(text: text, style: style));
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
