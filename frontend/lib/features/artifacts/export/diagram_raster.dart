import '../checks/diagram_render.dart';
import '../checks/webview_diagram_renderer.dart';
import 'svg_raster.dart';

/// Draws Mermaid source as a figure for the PDF and Word writers.
typedef DiagramRasterizer = Future<RasterFigure?> Function(String source);

/// Draws [source] in the app's hidden Mermaid page (the 2× PNG it exports).
/// Null where there is no webview (Linux, web) or Mermaid rejects it; the
/// writers then print the source.
Future<RasterFigure?> rasterizeDiagram(String source, {DiagramRenderer? renderer}) async {
  final r = renderer ?? appDiagramRenderer;
  if (r == null) return null;
  try {
    return switch (await r.render(source)) {
      final DiagramDrawn d => await d.figure(),
      DiagramFailed() => null,
    };
  } on DiagramUnavailable {
    return null;
  }
}

/// [source] drawn by the app's renderer, for the SVG and PNG downloads of a
/// diagram; throws a [StateError] the download button shows.
Future<DiagramDrawn> drawnDiagram(String source) async {
  final r = appDiagramRenderer;
  if (r == null) throw StateError('Diagrams can only be exported where the app has a web view.');
  try {
    return switch (await r.render(source)) {
      final DiagramDrawn d => d,
      DiagramFailed(:final message) => throw StateError('Mermaid could not draw this diagram: $message'),
    };
  } on DiagramUnavailable catch (e) {
    throw StateError('The diagram could not be drawn (${e.reason}).');
  }
}
