import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../../../core/platform/platform_kind.dart';
import '../../../core/theme/every_theme.dart';
import '../../chat/ui/chat_markdown.dart';

import '../../chat/domain/message.dart';
import '../domain/artifact.dart';
import '../domain/chart_spec.dart';
import '../domain/figures.dart';
import '../export/chart_svg.dart';
import '../export/doc_model.dart';
import '../export/svg_raster.dart';
import '../domain/slide_pictures.dart';
import '../domain/slide_spec.dart';
import '../ui/renderers/slide_canvas.dart';
import 'capture.dart';
import 'diagram_render.dart';
import 'math_check.dart';
import 'slide_lint.dart';
import 'svg_lint.dart';

/// The client tool that shows the model what it made.
const lookTool = 'look';

/// The most pictures one look sends back (the server takes 6).
const _maxPictures = 6;

/// What a look found: the text the model reads and the PNGs it sees with it.
typedef LookAnswer = ({String text, bool isError, List<Uint8List> pictures, List<String> findings});

/// What the chat keeps of a look on its call (the check row shows it): the findings, and the first pictures
/// shrunk, so the row can show what the model saw without storing every slide.
String lookRecord(String id, LookAnswer a, {List<Uint8List> thumbnails = const []}) => jsonEncode({
  'id': id,
  'error': a.isError ? a.text : null,
  'findings': a.findings,
  'pictures': [for (final t in thumbnails.take(3)) base64Encode(t)],
});

/// Draws what the model made (a figure, chart, diagram or document) the way the user sees it, lints it, and
/// answers `look` with the pictures and the findings, so the model can check its work and revise it, as the
/// coding tools' screenshot does for an app.
class Looker {
  const Looker({
    this.diagrams,
    this.rasterize = _lookRaster,
    this.captureSlide = _captureSlide,
    this.capturePages = _capturePages,
    this.prepareSvg = _same,
  });

  /// Applied to a figure's SVG before a slide draws it (the figure rig names a bundled font).
  final String Function(String svg) prepareSvg;

  /// Draws Mermaid; null where the platform has no webview.
  final DiagramRenderer? diagrams;

  /// Draws an SVG to a PNG (flutter_svg, as the app shows it).
  final SvgRasterizer rasterize;

  /// Draws one slide as presented, or null when it can't.
  final Future<Uint8List?> Function(DeckSlide slide, SlideArtBook art) captureSlide;

  /// Draws a markdown document's pages (empty when it can't).
  final Future<List<Uint8List>> Function(String markdown) capturePages;

  /// Answers one `look` call ([argumentsJson] as the model sent it) against the chat so far, this turn included.
  /// Never throws.
  Future<LookAnswer> look(String argumentsJson, Iterable<Message> history) async {
    final args = _decode(argumentsJson);
    final id = switch (args['id']) {
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
        'svg' => await _figure(
          id,
          v.str('content'),
          'SVG figure',
          script: artifact.versions.last.args.containsKey('code'),
        ),
        'chart' => await _chart(id, v),
        'mermaid' => await _diagram(id, v.str('content')),
        'markdown' || '' when v.kind == VisualKind.document => await _document(id, v.str('content'), figures),
        'slides' => await _deck(id, v, artifacts, switch (args['slide']) {
          final num n => n.toInt(),
          _ => null,
        }),
        final kind => _error(
          'Error: look can draw figures, charts, diagrams, slide decks and markdown documents; "$id" is ${kind.isEmpty ? v.kind.label.toLowerCase() : kind}.',
        ),
      };
    } on Object catch (e) {
      return _error('Error: could not draw "$id" ($e).');
    }
  }

  /// An SVG [svg] just made (by `svg_script`), as `look` would show the figure [id].
  Future<LookAnswer> figure(String id, String svg, String what) => _figure(id, svg, what, script: true);

  /// [script]: the figure comes from svg_script, so it is revised by running the program again.
  Future<LookAnswer> _figure(String id, String svg, String what, {bool script = false}) async {
    final findings = svgFindings(svg);
    final png = (await rasterize(svg))?.png;
    return _answer(
      id,
      what,
      [?png],
      findings,
      fix: script
          ? 'svg_script again with id "$id" and the program changed (a new run replaces the figure, including any '
                'edit_artifact changes)'
          : null,
    );
  }

  Future<LookAnswer> _chart(String id, Visual v) async {
    final spec = ChartSpec.tryParse(v.str('content')) ?? ChartSpec.fromJson(v.args);
    final svg = chartSvg(spec);
    if (svg == null) return _error('Error: the chart "$id" has no data the app can draw.');
    final png = (await rasterize(svg))?.png;
    return _answer(id, 'chart (as exported to PDF and Word)', [?png], svgFindings(svg));
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
    final pictures = [...await capturePages(expanded)];
    final pageCount = pictures.length;
    // A figure shown by reference is named by its own id: that is what edit_artifact revises.
    final idOf = {for (final f in figures.values) f.source.trim(): f.id};
    for (final (i, svg) in svgFiguresIn(expanded).indexed) {
      final name = switch (idOf[svg.trim()]) {
        final String figId => 'Figure ${i + 1} ("$figId", edit it by that id)',
        null => 'Figure ${i + 1}',
      };
      for (final f in svgFindings(svg)) {
        findings.add('$name: $f');
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
    final what = pageCount == 0
        ? 'document ($words words, $headings headings; the pictures are its figures in order)'
        : 'document ($words words, $headings headings): the first $pageCount picture(s) are its pages, where each '
              'SVG or Mermaid figure is a placeholder line; the rest are those figures, in order';
    return _answer(id, what, pictures, findings);
  }

  /// A deck's slides as presented (all of them up to six, or slide [only]), with each slide's findings.
  Future<LookAnswer> _deck(String id, Visual v, List<Artifact> artifacts, int? only) async {
    final deck = deckOf(v);
    if (only != null && (only < 1 || only > deck.length)) {
      return _error('Error: "$id" has slides 1 to ${deck.length} (slide 1 is the title slide).');
    }
    final indexes = only != null ? [only - 1] : [for (var i = 0; i < deck.length && i < _maxPictures; i++) i];
    final art = await drawSlideArt(
      pictureRefsOf(deck),
      slideSourcesOf(artifacts),
      diagrams: diagrams,
      prepare: prepareSvg,
    );
    try {
      final pictures = <Uint8List>[];
      final findings = <String>[];
      for (final i in indexes) {
        if (await captureSlide(deck[i], art) case final png?) pictures.add(png);
        for (final f in slideFindings(deck[i], art)) {
          findings.add('Slide ${i + 1}: $f');
        }
      }
      final shown = only != null
          ? 'slide $only of ${deck.length}'
          : 'slide deck, slides 1-${indexes.length} of ${deck.length}${deck.length > indexes.length ? ' (pass slide: N to see the others)' : ''}';
      return _answer(id, shown, pictures, findings);
    } finally {
      art.dispose();
    }
  }

  LookAnswer _answer(String id, String what, List<Uint8List> pictures, List<String> findings, {String? fix}) {
    final how = fix ?? 'edit_artifact on "$id"';
    final shown = pictures.isEmpty
        ? 'Could not draw a picture of "$id" ($what).'
        : 'The ${pictures.length == 1 ? 'picture shows' : '${pictures.length} pictures show'} "$id", $what, as the user sees it.';
    final checks = findings.isEmpty
        ? 'The checks found nothing wrong. Judge the picture yourself: does it show what was asked, is everything '
              'legible, aligned and balanced, nothing cut off or hidden? Fix what is off with $how.'
        : 'The checks found:\n${findings.map((f) => '- $f').join('\n')}\nFix these with $how, and '
              'anything else the picture shows is off.';
    return (text: '$shown\n$checks', isError: false, pictures: pictures, findings: findings);
  }

  static LookAnswer _error(String text) => (text: text, isError: true, pictures: const [], findings: const []);
}

String _same(String svg) => svg;

/// A slide at 768×432, as the canvas draws it.
Future<Uint8List?> _captureSlide(DeckSlide slide, SlideArtBook art) async {
  try {
    return await captureWidget(
      SlideCanvas(slide: slide, art: art),
      size: const Size(slideWidth, slideHeight),
      pixelRatio: 0.8,
    );
  } on Object {
    return null;
  }
}

/// A document as the chat draws it, 720 wide on white, cut into pages 960 tall (at most 4). SVG and Mermaid
/// blocks become a placeholder line: the look returns them as their own pictures, and the webview can't draw
/// offscreen.
Future<List<Uint8List>> _capturePages(String markdown) async {
  var n = 0;
  final text = markdown.replaceAllMapped(
    RegExp(r'^```(svg|mermaid)\s*\n[\s\S]*?^```\s*$', multiLine: true),
    (m) => '> *[${m.group(1) == 'svg' ? 'Figure' : 'Diagram'} ${++n}: drawn in its own picture]*',
  );
  try {
    final image = await captureImage(
      EveryThemeScope(
        theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
        child: Builder(
          builder: (context) => ColoredBox(
            color: const Color(0xFFFFFFFF),
            child: Padding(padding: const EdgeInsets.all(28), child: ChatMarkdown(text)),
          ),
        ),
      ),
      size: const Size(720, 9600),
      fitHeight: true,
    );
    if (image == null) return const [];
    try {
      return await pagesOf(image, pageHeight: 960, max: 4);
    } finally {
      image.dispose();
    }
  } on Object {
    return const [];
  }
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
