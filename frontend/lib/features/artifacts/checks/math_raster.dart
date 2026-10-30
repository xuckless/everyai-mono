import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_math_fork/flutter_math.dart';

import '../export/svg_raster.dart';
import 'math_check.dart';

/// Turns TeX into a figure for the PDF and Word writers; null when it can't.
typedef MathRasterizer = Future<RasterFigure?> Function(String tex);

/// Draws display math with flutter_math (the app's renderer), black on
/// white, at [scale]× for print. Null when the TeX doesn't parse.
Future<RasterFigure?> rasterizeTex(String tex, {double fontSize = 15, double scale = 3, double maxWidth = 480}) async {
  if (texError(tex) != null) return null;
  try {
    final image = await _renderOffscreen(
      Container(
        color: const Color(0xFFFFFFFF),
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        child: Math.tex(
          tex,
          mathStyle: MathStyle.display,
          textStyle: TextStyle(fontSize: fontSize, color: const Color(0xFF1F1F29)),
        ),
      ),
      pixelRatio: scale,
    );
    if (image == null) return null;
    final w = image.width / scale;
    final h = image.height / scale;
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (bytes == null || w <= 0 || h <= 0) return null;
    final fit = w > maxWidth ? maxWidth / w : 1.0;
    return (png: bytes.buffer.asUint8List(), width: w * fit, height: h * fit);
  } on Object {
    return null;
  }
}

/// Rasterizes every distinct expression once.
Future<Map<String, RasterFigure>> rasterizeAllTex(Iterable<String> texs, MathRasterizer rasterize) async {
  final out = <String, RasterFigure>{};
  for (final tex in texs.toSet()) {
    if (await rasterize(tex) case final r?) out[tex] = r;
  }
  return out;
}

/// Lays out and paints [child] in its own pipeline, outside the app's tree,
/// sized to its content (at most 2000×2000 logical pixels).
Future<ui.Image?> _renderOffscreen(Widget child, {required double pixelRatio}) async {
  final dispatcher = WidgetsBinding.instance.platformDispatcher;
  final view = dispatcher.implicitView ?? dispatcher.views.firstOrNull;
  if (view == null) return null;
  final boundary = RenderRepaintBoundary();
  final root = RenderView(
    view: view,
    configuration: const ViewConfiguration(
      logicalConstraints: BoxConstraints(maxWidth: 2000, maxHeight: 2000),
      physicalConstraints: BoxConstraints(maxWidth: 2000, maxHeight: 2000),
    ),
    child: RenderPositionedBox(alignment: Alignment.topLeft, child: boundary),
  );
  final pipeline = PipelineOwner()..rootNode = root;
  root.prepareInitialFrame();
  final build = BuildOwner(focusManager: FocusManager());
  final adapter = RenderObjectToWidgetAdapter<RenderBox>(
    container: boundary,
    child: MediaQuery(
      data: const MediaQueryData(),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: DefaultTextStyle(
          style: const TextStyle(color: Color(0xFF1F1F29)),
          child: child,
        ),
      ),
    ),
  );
  RenderObjectToWidgetElement<RenderBox>? element;
  try {
    element = adapter.attachToRenderTree(build);
    build
      ..buildScope(element)
      ..finalizeTree();
    pipeline
      ..flushLayout()
      ..flushCompositingBits()
      ..flushPaint();
    if (!boundary.hasSize || boundary.size.isEmpty) return null;
    return await boundary.toImage(pixelRatio: pixelRatio);
  } finally {
    // Unmount the widgets, then let the pipeline go.
    if (element != null) {
      RenderObjectToWidgetAdapter<RenderBox>(container: boundary).attachToRenderTree(build, element);
      build.finalizeTree();
    }
    pipeline.rootNode = null;
    pipeline.dispose();
    build.focusManager.dispose();
  }
}
