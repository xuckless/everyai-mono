import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../checks/diagram_render.dart';
import '../../domain/slide_pictures.dart';
import '../../domain/slide_spec.dart';
import 'svg_view.dart';

/// A picture ready to paint on a slide.
sealed class SlideArt {
  const SlideArt();
}

final class VectorArt extends SlideArt {
  const VectorArt(this.picture, this.size);
  final ui.Picture picture;
  final Size size;
}

final class RasterArt extends SlideArt {
  const RasterArt(this.image);
  final ui.Image image;
}

/// Still being drawn (the deck shows a faint box meanwhile).
final class PendingArt extends SlideArt {
  const PendingArt();
}

/// The reference names nothing in the chat, or it could not be drawn ([reason] says which).
final class MissingArt extends SlideArt {
  const MissingArt(this.reason);
  final String reason;
}

/// Pictures for the slides by reference, drawn ahead so a slide paints in one frame (on screen, in `look` and in
/// exports). [dispose] frees them.
final class SlideArtBook {
  SlideArtBook(this.art) : _pending = false;

  /// Nothing drawn yet: every picture is [PendingArt].
  SlideArtBook.pending() : art = const {}, _pending = true;

  final Map<String, SlideArt> art;
  final bool _pending;

  /// The picture [ref] names; drawn for [on] (the colour behind it) when it was drawn per backdrop (a chart).
  SlideArt of(String ref, {Color? on}) => _pending
      ? const PendingArt()
      : (on == null ? null : art[_toned(ref, on)]) ?? art[ref] ?? const MissingArt('not in this chat');

  void dispose() {
    for (final a in art.values.toSet()) {
      switch (a) {
        case VectorArt(:final picture):
          picture.dispose();
        case RasterArt(:final image):
          image.dispose();
        case MissingArt() || PendingArt():
      }
    }
  }
}

/// The key of [ref] drawn on [on].
String _toned(String ref, Color on) => '$ref@${on.toARGB32()}';

/// Draws every picture [uses] name from [sources]; Mermaid through [diagrams] where there is one. A chart is drawn
/// once for each colour it sits on.
Future<SlideArtBook> drawSlideArt(
  Iterable<PictureUse> uses,
  Map<String, SlideSource> sources, {
  DiagramRenderer? diagrams,
  String Function(String svg) prepare = _same,
}) async {
  final art = <String, SlideArt>{};
  for (final (:ref, :on) in uses) {
    final source = sources[ref];
    if (source case ChartSource()) {
      final drawn = switch (source.svgOn(on.toARGB32())) {
        final svg? => await _vector(prepare(svg)),
        null => const MissingArt('a chart with no data'),
      };
      art[_toned(ref, on)] = drawn;
      art.putIfAbsent(ref, () => drawn);
      continue;
    }
    if (art.containsKey(ref)) continue;
    art[ref] = switch (source) {
      null => const MissingArt('not in this chat'),
      SvgSource(:final svg) => await _vector(prepare(svg)),
      ChartSource() => const MissingArt('not in this chat'),
      RasterSource(:final bytes) => await _raster(bytes),
      MermaidSource(:final source) => await _mermaid(source, diagrams),
    };
  }
  return SlideArtBook(art);
}

String _same(String svg) => svg;

Future<SlideArt> _vector(String svg) async {
  try {
    final info = await vg.loadPicture(SvgStringLoader(sanitizeSvg(svg)), null);
    return VectorArt(info.picture, info.size.isEmpty ? const Size(480, 320) : info.size);
  } on Object catch (e) {
    return MissingArt('the SVG could not be drawn ($e)');
  }
}

Future<SlideArt> _raster(List<int> bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
    final frame = await codec.getNextFrame();
    codec.dispose();
    return RasterArt(frame.image);
  } on Object catch (e) {
    return MissingArt('the image could not be decoded ($e)');
  }
}

Future<SlideArt> _mermaid(String source, DiagramRenderer? diagrams) async {
  if (diagrams == null) return const MissingArt('Mermaid needs the desktop app to draw');
  try {
    return switch (await diagrams.render(source)) {
      DiagramDrawn(:final svg) => await _vector(svg),
      DiagramFailed(:final message) => MissingArt('Mermaid could not draw it: $message'),
    };
  } on DiagramUnavailable catch (e) {
    return MissingArt('Mermaid could not start (${e.reason})');
  }
}

/// One slide at 960×540, scaled to the width it gets. Plain widgets with explicit styles (no app theme), so it
/// draws the same in the chat, in the panel and offscreen for `look`. Text that doesn't fit its box spills out
/// visibly rather than being cut, so the problem shows.
class SlideCanvas extends StatelessWidget {
  const SlideCanvas({super.key, required this.slide, required this.art});

  final DeckSlide slide;
  final SlideArtBook art;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: slideWidth / slideHeight,
      child: FittedBox(
        child: ClipRect(
          child: Container(
            width: slideWidth,
            height: slideHeight,
            color: slide.background,
            child: Stack(clipBehavior: Clip.none, children: [for (final e in slide.elements) _place(e)]),
          ),
        ),
      ),
    );
  }

  Widget _place(SlideElement e) {
    Widget child = switch (e) {
      TextElement() => _TextBox(e),
      ShapeElement() => _Shape(e),
      TableElement() => _Table(e),
      PictureElement() => _Picture(e, art.of(e.ref, on: colourBehind(slide, e) ?? slide.background)),
    };
    if (e.opacity < 1) child = Opacity(opacity: e.opacity, child: child);
    if (e.rotation != 0) child = Transform.rotate(angle: e.rotation * math.pi / 180, child: child);
    return Positioned(
      left: e.box.left,
      top: e.box.top,
      width: math.max(e.box.width, 1),
      height: math.max(e.box.height, 1),
      child: child,
    );
  }
}

/// The style a text box's runs share; used by the lint to measure overflow the same way.
TextStyle slideTextStyle(TextElement e) =>
    TextStyle(fontFamily: e.font.family, fontSize: e.size, height: e.lineHeight, fontWeight: e.weight, color: e.color);

/// A text box's paragraphs as one rich-text span per paragraph.
InlineSpan slideSpan(TextElement e, SlideParagraph p) => TextSpan(
  children: [
    for (final r in p.runs)
      TextSpan(
        text: r.text,
        style: TextStyle(fontWeight: r.bold ? FontWeight.w700 : null, fontStyle: r.italic ? FontStyle.italic : null),
      ),
  ],
);

/// How far a bullet's text is indented.
double bulletIndent(TextElement e) => e.size * 1.1;

class _TextBox extends StatelessWidget {
  const _TextBox(this.e);
  final TextElement e;

  @override
  Widget build(BuildContext context) {
    final style = slideTextStyle(e);
    final column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: switch (e.align) {
        TextAlign.center => CrossAxisAlignment.center,
        TextAlign.right => CrossAxisAlignment.end,
        _ => CrossAxisAlignment.stretch,
      },
      children: [
        for (final (i, p) in e.paragraphs.indexed)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : e.size * (p.bullet ? 0.35 : 0.2)),
            child: p.bullet
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: bulletIndent(e),
                        height: e.size * e.lineHeight,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            width: e.size * 0.3,
                            height: e.size * 0.3,
                            decoration: BoxDecoration(color: e.bulletColor ?? e.color, shape: BoxShape.circle),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text.rich(slideSpan(e, p), style: style, textAlign: e.align),
                      ),
                    ],
                  )
                : Text.rich(slideSpan(e, p), style: style, textAlign: e.align),
          ),
      ],
    );
    return Container(
      padding: EdgeInsets.all(e.padding),
      decoration: BoxDecoration(
        color: e.fill,
        borderRadius: e.radius > 0 ? BorderRadius.circular(e.radius) : null,
        border: e.border == null ? null : Border.all(color: e.border!, width: 2),
      ),
      child: OverflowBox(
        maxHeight: double.infinity,
        alignment: switch (e.valign) {
          VAlign.top => Alignment.topLeft,
          VAlign.middle => Alignment.centerLeft,
          VAlign.bottom => Alignment.bottomLeft,
        },
        child: DefaultTextStyle(style: style, child: column),
      ),
    );
  }
}

class _Shape extends StatelessWidget {
  const _Shape(this.e);
  final ShapeElement e;

  @override
  Widget build(BuildContext context) {
    if (e.kind == ShapeKind.line || e.kind == ShapeKind.arrow) {
      return CustomPaint(painter: _LinePainter(e));
    }
    final border = e.stroke != null && e.strokeWidth > 0 ? Border.all(color: e.stroke!, width: e.strokeWidth) : null;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: e.fill,
        border: border,
        shape: e.kind == ShapeKind.ellipse ? BoxShape.rectangle : BoxShape.rectangle,
        borderRadius: switch (e.kind) {
          ShapeKind.rounded => BorderRadius.circular(e.radius),
          ShapeKind.ellipse => BorderRadius.all(Radius.elliptical(e.box.width / 2, e.box.height / 2)),
          _ => null,
        },
      ),
    );
  }
}

class _LinePainter extends CustomPainter {
  const _LinePainter(this.e);
  final ShapeElement e;

  @override
  void paint(Canvas canvas, Size size) {
    final width = e.strokeWidth > 0 ? e.strokeWidth : 3.0;
    final paint = Paint()
      ..color = e.stroke ?? e.fill ?? const Color(0xFF000000)
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round;
    final from = Offset.zero;
    final to = Offset(e.box.width, e.box.height);
    canvas.drawLine(from, to, paint);
    if (e.kind == ShapeKind.arrow && to != from) {
      final angle = math.atan2(to.dy - from.dy, to.dx - from.dx);
      final head = width * 4;
      final path = Path()
        ..moveTo(to.dx, to.dy)
        ..lineTo(to.dx - head * math.cos(angle - 0.45), to.dy - head * math.sin(angle - 0.45))
        ..lineTo(to.dx - head * math.cos(angle + 0.45), to.dy - head * math.sin(angle + 0.45))
        ..close();
      canvas.drawPath(path, paint..style = PaintingStyle.fill);
    }
  }

  @override
  bool shouldRepaint(_LinePainter old) => old.e != e;
}

class _Table extends StatelessWidget {
  const _Table(this.e);
  final TableElement e;

  @override
  Widget build(BuildContext context) {
    final cols = e.columns;
    if (cols == 0) return const SizedBox.shrink();
    final style = TextStyle(fontFamily: SlideFont.sans.family, fontSize: e.size, height: 1.3, color: e.color);
    final side = BorderSide(color: e.stroke ?? const Color(0x33000000));
    return OverflowBox(
      maxHeight: double.infinity,
      alignment: Alignment.topLeft,
      child: Container(
        color: e.fill,
        child: Table(
          border: TableBorder(horizontalInside: side, top: side, bottom: side),
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: [
            for (final (i, row) in e.rows.indexed)
              TableRow(
                decoration: i == 0 && e.header ? BoxDecoration(color: e.headerFill) : null,
                children: [
                  for (var c = 0; c < cols; c++)
                    Container(
                      // Rows share the box's height; longer cells make their row taller.
                      constraints: BoxConstraints(minHeight: e.box.height / e.rows.length),
                      alignment: Alignment.centerLeft,
                      padding: EdgeInsets.symmetric(horizontal: e.size * 0.6, vertical: e.size * 0.4),
                      child: Text(
                        c < row.length ? row[c] : '',
                        style: i == 0 && e.header
                            ? style.copyWith(fontWeight: FontWeight.w700, color: e.headerColor ?? e.color)
                            : style,
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _Picture extends StatelessWidget {
  const _Picture(this.e, this.art);
  final PictureElement e;
  final SlideArt art;

  @override
  Widget build(BuildContext context) {
    final fit = e.fit == PictureFit.cover ? BoxFit.cover : BoxFit.contain;
    final Widget child = switch (art) {
      VectorArt(:final picture, :final size) => FittedBox(
        fit: fit,
        clipBehavior: Clip.hardEdge,
        child: SizedBox.fromSize(
          size: size,
          child: CustomPaint(painter: _PicturePainter(picture)),
        ),
      ),
      RasterArt(:final image) => RawImage(image: image, fit: fit),
      PendingArt() => const ColoredBox(color: Color(0x0D000000)),
      MissingArt(:final reason) => Container(
        color: const Color(0x14000000),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(12),
        child: Text(
          '${e.ref}: $reason',
          textAlign: TextAlign.center,
          style: TextStyle(fontFamily: SlideFont.sans.family, fontSize: 14, color: const Color(0x99000000)),
        ),
      ),
    };
    return e.radius > 0 ? ClipRRect(borderRadius: BorderRadius.circular(e.radius), child: child) : child;
  }
}

class _PicturePainter extends CustomPainter {
  const _PicturePainter(this.picture);
  final ui.Picture picture;

  @override
  void paint(Canvas canvas, Size size) => canvas.drawPicture(picture);

  @override
  bool shouldRepaint(_PicturePainter old) => old.picture != picture;
}
