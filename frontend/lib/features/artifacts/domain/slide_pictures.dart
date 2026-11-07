import 'dart:convert';
import 'dart:typed_data';

import '../export/chart_svg.dart';
import 'artifact.dart';
import 'chart_spec.dart';

/// What a slide's picture reference ([PictureElement.ref]) draws.
sealed class SlideSource {
  const SlideSource();
}

/// An SVG figure (a chart is drawn as SVG, as in the PDF and Word exports).
final class SvgSource extends SlideSource {
  const SvgSource(this.svg);
  final String svg;
}

/// A Mermaid diagram: drawn by the app's webview renderer when there is one.
final class MermaidSource extends SlideSource {
  const MermaidSource(this.source);
  final String source;
}

/// A raster image (generated or uploaded).
final class RasterSource extends SlideSource {
  const RasterSource(this.bytes);
  final Uint8List bytes;
}

/// Pictures by the ids the model uses: figures and SVG artifacts, charts, diagrams and images, at their latest
/// version.
Map<String, SlideSource> slideSourcesOf(Iterable<Artifact> artifacts) {
  final out = <String, SlideSource>{};
  for (final a in artifacts) {
    final v = a.latest;
    final source = switch (v.kind) {
      VisualKind.svg => switch (v.args['svg'] ?? v.args['content']) {
        final String svg when svg.contains('<svg') => SvgSource(svg),
        _ => null,
      },
      VisualKind.chart => switch (chartSvg(ChartSpec.tryParse(v.str('content')) ?? ChartSpec.fromJson(v.args))) {
        final String svg => SvgSource(svg),
        null => null,
      },
      VisualKind.diagram => MermaidSource(v.args['mermaid'] as String? ?? v.str('content')),
      VisualKind.image => switch (v.args['bytes']) {
        final Uint8List bytes => RasterSource(bytes),
        _ => null,
      },
      _ => null,
    };
    if (source == null) continue;
    out[a.id] = source;
    // An image is also known by every version's own id (img_2 revises img_1).
    for (final version in a.versions) {
      if (version.args['image_id'] case final String imageId) out[imageId] = source;
    }
  }
  return out;
}

/// A short fingerprint of a source, for caches keyed by what is drawn.
String sourceKey(SlideSource s) => switch (s) {
  SvgSource(:final svg) => 'svg:${svg.hashCode}:${svg.length}',
  MermaidSource(:final source) => 'mmd:${source.hashCode}',
  RasterSource(:final bytes) => 'png:${bytes.length}:${base64Encode(bytes.take(32).toList())}',
};
