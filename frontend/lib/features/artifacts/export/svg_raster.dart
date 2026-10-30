import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../ui/renderers/svg_view.dart';

/// A rasterized figure: PNG bytes and the size it should be shown at, in points.
typedef RasterFigure = ({Uint8List png, double width, double height});

/// Turns SVG source into a raster figure; null when it can't be drawn.
typedef SvgRasterizer = Future<RasterFigure?> Function(String svg);

/// Draws [svg] with flutter_svg (the renderer the app shows) on white, at
/// [scale]× its intrinsic size, capped at [maxWidth] points.
Future<RasterFigure?> rasterizeSvg(String svg, {double maxWidth = 480, double scale = 2.5}) async {
  try {
    final info = await vg.loadPicture(SvgStringLoader(sanitizeSvg(svg)), null);
    final size = info.size.isEmpty ? const Size(480, 320) : info.size;
    final fit = size.width > maxWidth ? maxWidth / size.width : 1.0;
    final w = size.width * fit;
    final h = size.height * fit;
    final recorder = ui.PictureRecorder();
    Canvas(recorder)
      ..drawRect(Rect.fromLTWH(0, 0, w * scale, h * scale), Paint()..color = const Color(0xFFFFFFFF))
      ..scale(fit * scale)
      ..drawPicture(info.picture);
    final image = await recorder.endRecording().toImage((w * scale).ceil(), (h * scale).ceil());
    info.picture.dispose();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (bytes == null) return null;
    return (png: bytes.buffer.asUint8List(), width: w, height: h);
  } on Object {
    return null;
  }
}

/// Rasterizes every distinct figure once.
Future<Map<String, RasterFigure>> rasterizeAll(Iterable<String> svgs, SvgRasterizer rasterize) async {
  final out = <String, RasterFigure>{};
  for (final svg in svgs.toSet()) {
    if (await rasterize(svg) case final r?) out[svg] = r;
  }
  return out;
}
