import 'dart:convert';
import 'dart:typed_data';

import '../../chat/domain/message.dart';
import '../domain/artifact.dart';
import '../domain/chart_spec.dart';
import '../domain/figures.dart';
import '../export/chart_svg.dart';
import '../export/doc_model.dart';
import '../export/svg_raster.dart';
import 'diagram_render.dart';
import 'math_check.dart';
import 'svg_lint.dart';

/// The client tool that shows the model what it made.
const lookTool = 'look';

/// The most pictures one look sends back (the server takes 6).
const _maxPictures = 6;

/// What a look found: the text the model reads and the PNGs it sees with it.
typedef LookAnswer = ({String text, bool isError, List<Uint8List> pictures});

/// Draws what the model made (a figure, chart, diagram or document) the way the user sees it, lints it, and
/// answers `look` with the pictures and the findings, so the model can check its work and revise it, as the
/// coding tools' screenshot does for an app.
class Looker {
  const Looker({this.diagrams, this.rasterize = _lookRaster});

  /// Draws Mermaid; null where the platform has no webview.
  final DiagramRenderer? diagrams;

  /// Draws an SVG to a PNG (flutter_svg, as the app shows it).
  final SvgRasterizer rasterize;

  /// Answers one `look` call ([argumentsJson] as the model sent it) against the chat so far, this turn included.
  /// Never throws.
  Future<LookAnswer> look(String argumentsJson, Iterable<Message> history) async {
    final id = switch (_decode(argumentsJson)['id']) {
      final String s when s.trim().isNotEmpty => s.trim(),
      _ => null,
    };
    if (id == null) return _error('Error: give the id of what to look at (a figure, chart, diagram or artifact).');
    final artifacts = artifactsIn(history);
    final artifact = artifacts.where((a) => a.id == id).firstOrNull;
    if (artifact == null) {
      final known = artifacts.map((a) => a.id).take(12).join(', ');
      return _error('Error: nothing in this chat has the id "$id".${known.isEmpty ? '' : ' Ids here: $known.'}');
    }
    final v = artifact.latest;
    final figures = figuresOf(artifacts);
    try {
      return switch (v.str('kind')) {
        'svg' => await _figure(id, v.str('content'), 'SVG figure'),
        'chart' => await _chart(id, v),
        'mermaid' => await _diagram(id, v.str('content')),
        'markdown' || '' when v.kind == VisualKind.document => await _document(id, v.str('content'), figures),
        final kind => _error(
          'Error: look can draw figures, charts, diagrams and markdown documents; "$id" is ${kind.isEmpty ? v.kind.label.toLowerCase() : kind}.',
        ),
      };
    } on Object catch (e) {
      return _error('Error: could not draw "$id" ($e).');
    }
  }

  Future<LookAnswer> _figure(String id, String svg, String what) async {
    final findings = svgFindings(svg);
    final png = (await rasterize(svg))?.png;
    return _answer(id, what, [?png], findings);
  }

  Future<LookAnswer> _chart(String id, Visual v) async {
    final spec = ChartSpec.tryParse(v.str('content')) ?? ChartSpec.fromJson(v.args);
    final svg = chartSvg(spec);
    if (svg == null) return _error('Error: the chart "$id" has no data the app can draw.');
    final png = (await rasterize(svg))?.png;
    return _answer(id, 'chart (as exported to PDF and Word)', [?png], const []);
  }

  Future<LookAnswer> _diagram(String id, String source) async {
    final renderer = diagrams;
    if (renderer == null) return _error('Error: this device has no webview to draw Mermaid; look at the source.');
    try {
      return switch (await renderer.render(source)) {
        DiagramDrawn(:final png, :final svg) => _answer(id, 'Mermaid diagram', [
          ?png ?? (await rasterize(svg))?.png,
        ], const []),
        DiagramFailed(:final message) => _error('Error: Mermaid could not draw "$id": $message'),
      };
    } on DiagramUnavailable catch (e) {
      return _error('Error: Mermaid could not start here (${e.reason}).');
    }
  }

  /// A document's figures in order (with figure: references resolved), and what's wrong in the rest of it.
  Future<LookAnswer> _document(String id, String markdown, Map<String, Figure> figures) async {
    final findings = <String>[
      for (final ref in figureRefsIn(markdown))
        if (!figures.containsKey(ref)) 'It shows figure "$ref", which is not in this chat.',
      for (final p in mathProblems(markdown)) 'Math $p',
    ];
    final expanded = expandFigureRefs(markdown, figures);
    final pictures = <Uint8List>[];
    for (final (i, svg) in svgFiguresIn(expanded).indexed) {
      for (final f in svgFindings(svg)) {
        findings.add('Figure ${i + 1}: $f');
      }
      if (pictures.length < _maxPictures) {
        if ((await rasterize(svg))?.png case final png?) pictures.add(png);
      }
    }
    final renderer = diagrams;
    for (final (i, source) in diagramSourcesIn(expanded).indexed) {
      if (renderer == null) break;
      try {
        switch (await renderer.render(source)) {
          case DiagramDrawn(:final png?) when pictures.length < _maxPictures:
            pictures.add(png);
          case DiagramFailed(:final message):
            findings.add('Mermaid block ${i + 1}: $message');
          case DiagramDrawn():
        }
      } on DiagramUnavailable {
        break;
      }
    }
    final words = RegExp(r'\S+').allMatches(expanded.replaceAll(RegExp(r'```[\s\S]*?```'), '')).length;
    final headings = RegExp(r'^#{1,6} ', multiLine: true).allMatches(expanded).length;
    final what = 'document ($words words, $headings headings; the pictures are its figures in order)';
    return _answer(id, what, pictures, findings);
  }

  LookAnswer _answer(String id, String what, List<Uint8List> pictures, List<String> findings) {
    final shown = pictures.isEmpty
        ? 'Could not draw a picture of "$id" ($what).'
        : 'The ${pictures.length == 1 ? 'picture shows' : '${pictures.length} pictures show'} "$id", $what, as the user sees it.';
    final checks = findings.isEmpty
        ? 'The checks found nothing wrong. Judge the picture yourself: does it show what was asked, is everything '
              'legible, aligned and balanced, nothing cut off or hidden? Fix what is off with edit_artifact on "$id".'
        : 'The checks found:\n${findings.map((f) => '- $f').join('\n')}\nFix these with edit_artifact on "$id", and '
              'anything else the picture shows is off.';
    return (text: '$shown\n$checks', isError: false, pictures: pictures);
  }

  static LookAnswer _error(String text) => (text: text, isError: true, pictures: const []);
}

/// Pictures for the model: at most 768 px across, so a look costs about one image's tokens.
Future<RasterFigure?> _lookRaster(String svg) => rasterizeSvg(svg, maxWidth: 384, scale: 2);

Map<String, Object?> _decode(String json) {
  try {
    return switch (jsonDecode(json)) {
      final Map<String, Object?> m => m,
      _ => const {},
    };
  } on FormatException {
    return const {};
  }
}

/// A PNG as the data URL the server takes.
String pngDataUrl(Uint8List png) => 'data:image/png;base64,${base64Encode(png)}';
