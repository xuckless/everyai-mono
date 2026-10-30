import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../export/svg_raster.dart';

/// What drawing a Mermaid diagram produced.
sealed class DiagramRender {
  const DiagramRender();
}

/// Mermaid drew it: a cleaned-up standalone SVG, its size in CSS pixels and,
/// unless the canvas export failed, a 2× PNG on white.
final class DiagramDrawn extends DiagramRender {
  const DiagramDrawn({required this.svg, required this.width, required this.height, this.png});
  final String svg;
  final double width;
  final double height;
  final Uint8List? png;

  /// The PNG as a figure for the PDF and Word writers, at most [maxWidth]
  /// points wide; falls back to drawing [svg] with flutter_svg.
  Future<RasterFigure?> figure({double maxWidth = 480, SvgRasterizer? fallback}) async {
    final png = this.png;
    if (png != null && width > 0 && height > 0) {
      final fit = width > maxWidth ? maxWidth / width : 1.0;
      return (png: png, width: width * fit, height: height * fit);
    }
    return (fallback ?? rasterizeSvg)(svg);
  }
}

/// Mermaid rejected the source; [message] is its parse or render error.
final class DiagramFailed extends DiagramRender {
  const DiagramFailed(this.message);
  final String message;
}

/// Thrown when no webview could draw the diagram (it didn't load, or timed out).
final class DiagramUnavailable implements Exception {
  const DiagramUnavailable(this.reason);
  final String reason;
  @override
  String toString() => 'DiagramUnavailable: $reason';
}

/// Decodes what `everyaiRenderMermaid` (assets/web/mermaid_export.js) returned.
DiagramRender diagramRenderFromJs(Object? value) {
  final map = switch (value) {
    final Map<Object?, Object?> m => m,
    final String s => switch (jsonDecode(s)) {
      final Map<Object?, Object?> m => m,
      _ => throw const DiagramUnavailable('unexpected result'),
    },
    _ => throw const DiagramUnavailable('no result'),
  };
  if (map['ok'] != true) {
    final error = map['error'];
    return DiagramFailed(error is String && error.trim().isNotEmpty ? error.trim() : 'Mermaid could not parse it');
  }
  final svg = map['svg'];
  if (svg is! String || svg.isEmpty) throw const DiagramUnavailable('no SVG came back');
  Uint8List? png;
  if (map['png'] case final String b64 when b64.isNotEmpty) {
    try {
      png = base64Decode(b64);
    } on FormatException {
      png = null;
    }
  }
  return DiagramDrawn(
    svg: svg,
    width: (map['width'] as num?)?.toDouble() ?? 0,
    height: (map['height'] as num?)?.toDouble() ?? 0,
    png: png,
  );
}

/// Draws Mermaid source; see [WebviewDiagramRenderer].
abstract interface class DiagramRenderer {
  /// Throws [DiagramUnavailable] when there is nothing to draw with.
  Future<DiagramRender> render(String source);
}

/// Runs one render at a time through [draw] and remembers the last [capacity]
/// results by source, so the check during a turn and a later export share one
/// render.
class CachingDiagramRenderer implements DiagramRenderer {
  CachingDiagramRenderer(this.draw, {this.capacity = 32});

  final Future<DiagramRender> Function(String source) draw;
  final int capacity;
  final _cache = <String, Future<DiagramRender>>{};
  Future<void> _queue = Future.value();

  @override
  Future<DiagramRender> render(String source) {
    final key = source.trim();
    final hit = _cache.remove(key);
    if (hit != null) return _cache[key] = hit;
    final done = Completer<DiagramRender>();
    _queue = _queue.then((_) async {
      try {
        done.complete(await draw(key));
      } on Object catch (e, st) {
        done.completeError(e, st);
      }
    });
    final result = done.future;
    _cache[key] = result;
    // A failure to draw at all isn't remembered: the next call tries again.
    result.then<void>(
      (_) {},
      onError: (Object _) {
        if (identical(_cache[key], result)) _cache.remove(key);
      },
    );
    while (_cache.length > capacity) {
      _cache.remove(_cache.keys.first);
    }
    return result;
  }
}
