import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Draws [widget] offscreen at [size] (logical pixels) and returns it as a PNG at [pixelRatio], without putting it
/// on screen: its own render tree and build owner, laid out and painted once. The widget must paint in its first
/// frame (pictures decoded ahead, no animations); `look` uses it for slides and document pages.
Future<Uint8List?> captureWidget(Widget widget, {required Size size, double pixelRatio = 1}) async {
  final image = await captureImage(widget, size: size, pixelRatio: pixelRatio);
  if (image == null) return null;
  try {
    return await pngOf(image);
  } finally {
    image.dispose();
  }
}

/// [image] as PNG bytes.
Future<Uint8List?> pngOf(ui.Image image) async =>
    (await image.toByteData(format: ui.ImageByteFormat.png))?.buffer.asUint8List();

/// [image] cut into pieces at most [pageHeight] tall (in the image's pixels), top to bottom, at most [max], as PNGs.
/// Each cut falls in a gap between lines where there is one ([pageBreaks]), so no line is split across pages.
Future<List<Uint8List>> pagesOf(ui.Image image, {required int pageHeight, int max = 6}) async {
  final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final breaks = rgba == null
      ? [for (var y = pageHeight; y < image.height; y += pageHeight) y]
      : pageBreaks(rgba.buffer.asUint8List(), image.width, image.height, pageHeight: pageHeight);
  final out = <Uint8List>[];
  var top = 0;
  for (final bottom in [...breaks, image.height]) {
    if (out.length >= max) break;
    final h = bottom - top;
    if (h <= 0) continue;
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImageRect(
      image,
      Rect.fromLTWH(0, top.toDouble(), image.width.toDouble(), h.toDouble()),
      Rect.fromLTWH(0, 0, image.width.toDouble(), h.toDouble()),
      Paint(),
    );
    final page = await recorder.endRecording().toImage(image.width, h);
    if (await pngOf(page) case final png?) out.add(png);
    page.dispose();
    top = bottom;
  }
  return out;
}

/// Where to cut a picture [width]×[height] (RGBA bytes) into pages at most [pageHeight] tall: the rows each page
/// ends at, top to bottom. A page ends on the quietest row in its last [search] rows (the fewest colour changes
/// across it, the lowest on a tie), which is the gap between two lines of text; it ends at [pageHeight] when every
/// row there crosses something (a picture), as a plain cut would.
List<int> pageBreaks(Uint8List rgba, int width, int height, {required int pageHeight, int search = 240}) {
  int changes(int y) {
    var n = 0;
    final row = y * width * 4;
    for (var x = 1; x < width; x++) {
      final a = row + (x - 1) * 4, b = row + x * 4;
      final d = (rgba[a] - rgba[b]).abs() + (rgba[a + 1] - rgba[b + 1]).abs() + (rgba[a + 2] - rgba[b + 2]).abs();
      if (d > 24) n++;
    }
    return n;
  }

  // A row crossing a box's edges only (a table, a code block, a quote bar) is still a gap between its lines.
  final quiet = math.max(8, width ~/ 40);
  final out = <int>[];
  var top = 0;
  while (height - top > pageHeight) {
    final limit = top + pageHeight;
    var best = limit, fewest = quiet + 1;
    for (var y = limit - 1; y > limit - search && y > top + pageHeight ~/ 2; y--) {
      final n = changes(y);
      if (n < fewest) (best, fewest) = (y + 1, n);
      if (n == 0) break;
    }
    out.add(best);
    top = best;
  }
  return out;
}

/// [captureWidget] as an image. With [fitHeight] the widget gets [size]'s width and takes the height it needs (up
/// to [size]'s), for documents.
Future<ui.Image?> captureImage(
  Widget widget, {
  required Size size,
  double pixelRatio = 1,
  bool fitHeight = false,
}) async {
  final view = ui.PlatformDispatcher.instance.implicitView ?? ui.PlatformDispatcher.instance.views.first;
  final boundary = RenderRepaintBoundary();
  final renderView = RenderView(
    view: view,
    child: RenderPositionedBox(alignment: Alignment.topLeft, child: boundary),
    configuration: ViewConfiguration(
      logicalConstraints: BoxConstraints.tight(size),
      physicalConstraints: BoxConstraints.tight(size * pixelRatio),
      devicePixelRatio: pixelRatio,
    ),
  );
  final pipeline = PipelineOwner()..rootNode = renderView;
  renderView.prepareInitialFrame();
  final build = BuildOwner(focusManager: FocusManager());
  final root = RenderObjectToWidgetAdapter<RenderBox>(
    container: boundary,
    child: MediaQuery(
      data: MediaQueryData(size: size, devicePixelRatio: pixelRatio),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: fitHeight ? SizedBox(width: size.width, child: widget) : SizedBox.fromSize(size: size, child: widget),
      ),
    ),
  ).attachToRenderTree(build);
  try {
    build
      ..buildScope(root)
      ..finalizeTree();
    pipeline
      ..flushLayout()
      ..flushCompositingBits()
      ..flushPaint();
    return await boundary.toImage(pixelRatio: pixelRatio);
  } finally {
    // Unmount the widget tree (an empty adapter replaces it) so its elements and render objects are released.
    RenderObjectToWidgetAdapter<RenderBox>(container: boundary).attachToRenderTree(build, root);
    build.finalizeTree();
  }
}

/// [pngs] scaled down to [width] pixels across (kept as they are when smaller or undecodable), for thumbnails.
Future<List<Uint8List>> shrinkPngs(Iterable<Uint8List> pngs, {int width = 320}) async {
  final out = <Uint8List>[];
  for (final png in pngs) {
    try {
      final codec = await ui.instantiateImageCodec(png, targetWidth: width);
      final frame = await codec.getNextFrame();
      codec.dispose();
      final small = await pngOf(frame.image);
      frame.image.dispose();
      out.add(small != null && small.length < png.length ? small : png);
    } on Object {
      out.add(png);
    }
  }
  return out;
}
