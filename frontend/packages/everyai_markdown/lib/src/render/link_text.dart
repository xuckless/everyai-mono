import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A text run that belongs to a link.
///
/// Every leaf span inside a link is a [LinkTextSpan] so that a tap can be
/// resolved to its href by hit-testing the paragraph, without gesture
/// recognizers on the spans themselves.
class LinkTextSpan extends TextSpan {
  const LinkTextSpan({required String super.text, super.style, required this.href})
    : super(mouseCursor: SystemMouseCursors.click);

  final String href;

  @override
  bool operator ==(Object other) => super == other && other is LinkTextSpan && other.href == href;

  @override
  int get hashCode => Object.hash(super.hashCode, href);
}

/// A [Text.rich] that reports taps on [LinkTextSpan]s.
///
/// Plain [Text.rich] is used so the text participates in an enclosing
/// `SelectionArea`; tap detection works by mapping the tap position to a
/// text position on the underlying [RenderParagraph].
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

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapUp: _handleTapUp,
      child: Text.rich(widget.span, key: _textKey, textAlign: widget.textAlign),
    );
  }
}
