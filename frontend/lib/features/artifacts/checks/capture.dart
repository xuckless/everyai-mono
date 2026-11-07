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
Future<List<Uint8List>> pagesOf(ui.Image image, {required int pageHeight, int max = 6}) async {
  final out = <Uint8List>[];
  for (var top = 0; top < image.height && out.length < max; top += pageHeight) {
    final h = (image.height - top).clamp(1, pageHeight);
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
