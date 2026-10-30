import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A text run that belongs to a link.
///
/// Every leaf span inside a link is a [LinkTextSpan] so that a tap can be
/// resolved to its href by hit-testing the paragraph, without gesture
/// recognizers on the spans themselves. All runs of one link element share a
/// [group], so hover effects cover the whole link.
class LinkTextSpan extends TextSpan {
  const LinkTextSpan({
    required String super.text,
    super.style,
    required this.href,
    this.group = 0,
    super.onEnter,
    super.onExit,
  }) : super(mouseCursor: SystemMouseCursors.click);

  final String href;
  final int group;

  @override
  bool operator ==(Object other) =>
      super == other && other is LinkTextSpan && other.href == href && other.group == group;

  @override
  int get hashCode => Object.hash(super.hashCode, href, group);
}

/// A [Text.rich] that reports taps on [LinkTextSpan]s and underlines the
/// link under the mouse pointer.
///
/// Plain [Text.rich] is used so the text participates in an enclosing
/// `SelectionArea`; tap detection works by mapping the tap position to a
/// text position on the underlying [RenderParagraph]. Hover tracking uses the
/// spans' own mouse regions ([TextSpan.onEnter] / [TextSpan.onExit]).
class LinkAwareText extends StatefulWidget {
  const LinkAwareText({super.key, required this.span, required this.onTapLink, this.textAlign});

  final InlineSpan span;
  final ValueChanged<String> onTapLink;
  final TextAlign? textAlign;

  @override
  State<LinkAwareText> createState() => _LinkAwareTextState();
}

class _LinkAwareTextState extends State<LinkAwareText> {
  final GlobalKey _textKey = GlobalKey();
  int? _hovered;

  InlineSpan? _decorated;
  InlineSpan? _decoratedFrom;
  int? _decoratedHover;

  void _handleTapUp(TapUpDetails details) {
    final renderObject = _textKey.currentContext?.findRenderObject();
    if (renderObject is! RenderParagraph) return;
    final local = renderObject.globalToLocal(details.globalPosition);
    final position = renderObject.getPositionForOffset(local);
    final span = renderObject.text.getSpanForPosition(position);
    if (span is! LinkTextSpan) return;
    // getPositionForOffset snaps to the nearest position, so make sure the
    // tap is actually on a glyph next to that position.
    final textLength = renderObject.text.toPlainText().length;
    final start = (position.offset - 1).clamp(0, textLength);
    final end = (position.offset + 1).clamp(0, textLength);
    final boxes = renderObject.getBoxesForSelection(TextSelection(baseOffset: start, extentOffset: end));
    final hit = boxes.any((box) => box.toRect().inflate(2).contains(local));
    if (hit) widget.onTapLink(span.href);
  }

  void _setHovered(int? group) {
    if (_hovered != group && mounted) setState(() => _hovered = group);
  }

  InlineSpan _decorate(InlineSpan span) {
    if (span is LinkTextSpan) {
      final group = span.group;
      var style = span.style;
      if (group == _hovered) {
        style = (style ?? const TextStyle()).copyWith(
          decoration: TextDecoration.combine(<TextDecoration>[
            if (style?.decoration != null) style!.decoration!,
            TextDecoration.underline,
          ]),
          decorationColor: style?.decorationColor ?? style?.color,
        );
      }
      return LinkTextSpan(
        text: span.text!,
        style: style,
        href: span.href,
        group: group,
        onEnter: (_) => _setHovered(group),
        onExit: (_) {
          if (_hovered == group) _setHovered(null);
        },
      );
    }
    if (span is TextSpan && span.children != null) {
      return TextSpan(
        text: span.text,
        style: span.style,
        recognizer: span.recognizer,
        mouseCursor: span.mouseCursor,
        semanticsLabel: span.semanticsLabel,
        locale: span.locale,
        spellOut: span.spellOut,
        children: <InlineSpan>[for (final child in span.children!) _decorate(child)],
      );
    }
    return span;
  }

  @override
  Widget build(BuildContext context) {
    if (_decorated == null || !identical(_decoratedFrom, widget.span) || _decoratedHover != _hovered) {
      _decorated = _decorate(widget.span);
      _decoratedFrom = widget.span;
      _decoratedHover = _hovered;
    }
    return GestureDetector(
      onTapUp: _handleTapUp,
      child: Text.rich(_decorated!, key: _textKey, textAlign: widget.textAlign),
    );
  }
}
