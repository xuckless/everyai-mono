import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'artifact.dart';

/// The slide canvas: every slide is laid out at 960×540 (16:9) and scaled to fit.
const slideWidth = 960.0;
const slideHeight = 540.0;
const _margin = 64.0;

/// Colors of a deck theme (`make_slides.theme`).
@immutable
final class DeckTheme {
  const DeckTheme(this.background, this.title, this.text, this.accent);

  static DeckTheme of(String name) => switch (name) {
    'dark' => const DeckTheme(Color(0xFF16181D), Color(0xFFFFFFFF), Color(0xFFD5D8DE), Color(0xFF8B7CF6)),
    'navy' => const DeckTheme(Color(0xFF0F2547), Color(0xFFFFFFFF), Color(0xFFD6E2F5), Color(0xFF5FB3F9)),
    'minimal' => const DeckTheme(Color(0xFFFAFAF7), Color(0xFF111111), Color(0xFF333333), Color(0xFF111111)),
    _ => const DeckTheme(Color(0xFFFFFFFF), Color(0xFF1C1B22), Color(0xFF3A3A44), Color(0xFF6E56CF)),
  };

  final Color background;
  final Color title;
  final Color text;
  final Color accent;

  /// A muted text colour: [text] at 70%.
  Color get muted => text.withValues(alpha: 0.7);

  /// A colour the model wrote: `#rgb`, `#rrggbb`, `#rrggbbaa`, or a theme name (accent, text, title, background,
  /// muted); [fallback] when it's none of those.
  Color color(Object? raw, Color fallback) {
    if (raw is! String) return fallback;
    final v = raw.trim().toLowerCase();
    switch (v) {
      case 'accent':
        return accent;
      case 'text':
        return text;
      case 'title':
        return title;
      case 'background':
        return background;
      case 'muted':
        return muted;
      case 'white':
        return const Color(0xFFFFFFFF);
      case 'black':
        return const Color(0xFF000000);
      case 'none' || 'transparent':
        return const Color(0x00000000);
    }
    final hex = RegExp(r'^#([0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$').firstMatch(v)?.group(1);
    if (hex == null) return fallback;
    final full = hex.length == 3 ? hex.split('').map((c) => '$c$c').join() : hex;
    final rgb = int.parse(full.substring(0, 6), radix: 16);
    final alpha = full.length == 8 ? int.parse(full.substring(6), radix: 16) : 0xFF;
    return Color(alpha << 24 | rgb);
  }
}

/// Where a box's text sits vertically.
enum VAlign { top, middle, bottom }

/// The three faces a slide can use; each maps to a bundled font in the app and a common one in PowerPoint.
enum SlideFont {
  sans('Geist', 'Calibri'),
  serif('Georgia', 'Georgia'),
  mono('GeistMono', 'Consolas');

  const SlideFont(this.family, this.office);
  final String family;
  final String office;
}

/// A run of text with its own weight or slant (`**bold**`, `*italic*` in the model's text).
typedef SlideRun = ({String text, bool bold, bool italic});

/// One paragraph of a text box: its runs, and whether it is a bullet (a line starting "- ").
typedef SlideParagraph = ({List<SlideRun> runs, bool bullet});

/// Something placed on a slide, in canvas units (960×540), drawn in order (later on top).
sealed class SlideElement {
  const SlideElement({required this.box, this.rotation = 0, this.opacity = 1, this.name});

  final Rect box;

  /// Degrees clockwise about the box's centre.
  final double rotation;
  final double opacity;

  /// The model's id for it, if any (findings name it).
  final String? name;

  /// How findings refer to it.
  String get label;
}

final class TextElement extends SlideElement {
  const TextElement({
    required super.box,
    required this.paragraphs,
    required this.size,
    required this.color,
    this.weight = FontWeight.w400,
    this.align = TextAlign.left,
    this.valign = VAlign.top,
    this.font = SlideFont.sans,
    this.fill,
    this.border,
    this.radius = 0,
    this.padding = 0,
    this.lineHeight = 1.3,
    this.bulletColor,
    super.rotation,
    super.opacity,
    super.name,
  });

  final List<SlideParagraph> paragraphs;
  final double size;
  final Color color;
  final FontWeight weight;
  final TextAlign align;
  final VAlign valign;
  final SlideFont font;
  final Color? fill;
  final Color? border;
  final double radius;
  final double padding;
  final double lineHeight;
  final Color? bulletColor;

  String get plainText => paragraphs.map((p) => p.runs.map((r) => r.text).join()).join('\n');

  @override
  String get label {
    final t = plainText.replaceAll('\n', ' ');
    return name ?? 'text "${t.length > 28 ? '${t.substring(0, 28)}…' : t}"';
  }
}

enum ShapeKind { rect, rounded, ellipse, line, arrow }

final class ShapeElement extends SlideElement {
  const ShapeElement({
    required super.box,
    required this.kind,
    this.fill,
    this.stroke,
    this.strokeWidth = 0,
    this.radius = 16,
    super.rotation,
    super.opacity,
    super.name,
  });

  /// Lines and arrows run from the box's top-left corner to its bottom-right one (a zero width or height makes
  /// them straight).
  final ShapeKind kind;
  final Color? fill;
  final Color? stroke;
  final double strokeWidth;
  final double radius;

  @override
  String get label => name ?? kind.name;
}

final class TableElement extends SlideElement {
  const TableElement({
    required super.box,
    required this.rows,
    required this.size,
    required this.color,
    this.header = true,
    this.fill,
    this.headerFill,
    this.headerColor,
    this.stroke,
    super.rotation,
    super.opacity,
    super.name,
  });

  final List<List<String>> rows;
  final double size;
  final Color color;
  final bool header;
  final Color? fill;
  final Color? headerFill;
  final Color? headerColor;
  final Color? stroke;

  int get columns => rows.fold(0, (n, r) => r.length > n ? r.length : n);

  @override
  String get label => name ?? 'table (${rows.length}×$columns)';
}

/// How a picture fills its box.
enum PictureFit { contain, cover }

/// A figure from the chat (`figure:` id) or an image (an `img_…` id or an image artifact).
final class PictureElement extends SlideElement {
  const PictureElement({
    required super.box,
    required this.ref,
    this.fit = PictureFit.contain,
    this.radius = 0,
    super.rotation,
    super.opacity,
    super.name,
  });

  final String ref;
  final PictureFit fit;
  final double radius;

  @override
  String get label => name ?? 'figure "$ref"';
}

/// One slide, laid out: its background and elements in paint order, and its notes.
@immutable
final class DeckSlide {
  const DeckSlide({required this.title, required this.background, required this.elements, this.notes = ''});

  final String title;
  final Color background;
  final List<SlideElement> elements;
  final String notes;
}

/// The preset layouts a slide may name; `free` places only the model's own elements.
const slideLayouts = ['title', 'bullets', 'figure_right', 'figure_left', 'figure', 'background', 'grid', 'free'];

/// The deck in a `make_slides` call (or its latest version): a title slide, then the model's slides, each laid
/// out to elements. A first slide with layout `title` is the title slide (it can take a background and
/// elements); otherwise one is made from the deck's title and subtitle. Bad values fall back to defaults rather
/// than failing the deck.
List<DeckSlide> deckOf(Visual visual) {
  final theme = DeckTheme.of(visual.str('theme'));
  final slides = [
    for (final s in (visual.args['slides'] as List<Object?>?) ?? const [])
      if (s is Map<String, Object?>) s,
  ];
  final ownTitle = slides.firstOrNull?['layout'] == 'title';
  return [
    if (!ownTitle) _titleSlide(visual.title, visual.str('subtitle'), theme, const {}),
    for (final s in slides) slideOf(s, theme),
  ];
}

/// One slide from its JSON.
DeckSlide slideOf(Map<String, Object?> s, DeckTheme theme) {
  final title = s['title'] as String? ?? '';
  final layout = s['layout'] as String? ?? (s['figure'] != null ? 'figure_right' : 'bullets');
  final background = theme.color(s['background'], theme.background);
  final own = [
    for (final e in (s['elements'] as List<Object?>?) ?? const [])
      if (e is Map<String, Object?>) ?_element(e, theme),
  ];
  final notes = s['notes'] as String? ?? '';
  final preset = switch (layout) {
    'title' => _titleSlide(title, s['subtitle'] as String? ?? s['body'] as String? ?? '', theme, s).elements,
    'free' => const <SlideElement>[],
    'figure' => _figureSlide(title, s, theme),
    'figure_right' || 'figure_left' => _sideSlide(title, s, theme, figureLeft: layout == 'figure_left'),
    'background' => _backgroundSlide(title, s, theme),
    'grid' => _gridSlide(title, s, theme),
    _ => _bulletSlide(title, s, theme),
  };
  return DeckSlide(title: title, background: background, elements: [...preset, ...own], notes: notes);
}

DeckSlide _titleSlide(String title, String subtitle, DeckTheme theme, Map<String, Object?> s) => DeckSlide(
  title: title,
  background: theme.color(s['background'], theme.background),
  elements: [
    // An empty title leaves the slide to the model's own elements.
    if (title.isNotEmpty)
      ShapeElement(box: const Rect.fromLTWH(_margin, 176, 72, 6), kind: ShapeKind.rect, fill: theme.accent),
    if (title.isNotEmpty)
      TextElement(
        box: const Rect.fromLTWH(_margin, 206, slideWidth - 2 * _margin, 136),
        paragraphs: paragraphsOf(title),
        size: 56,
        weight: FontWeight.w800,
        color: theme.title,
        lineHeight: 1.1,
        valign: VAlign.bottom,
      ),
    if (subtitle.isNotEmpty)
      TextElement(
        box: const Rect.fromLTWH(_margin, 358, slideWidth - 2 * _margin, 80),
        paragraphs: paragraphsOf(subtitle),
        size: 26,
        color: theme.text,
      ),
  ],
);

/// The title and accent rule most layouts share.
List<SlideElement> _heading(String title, DeckTheme theme) => [
  TextElement(
    box: const Rect.fromLTWH(_margin, 48, slideWidth - 2 * _margin, 62),
    paragraphs: paragraphsOf(title),
    size: 40,
    weight: FontWeight.w700,
    color: theme.title,
    lineHeight: 1.15,
    valign: VAlign.bottom,
  ),
  ShapeElement(box: const Rect.fromLTWH(_margin, 122, 56, 4), kind: ShapeKind.rect, fill: theme.accent),
];

/// A slide's text: its bullets as "- " lines, then its body.
String _textOf(Map<String, Object?> s) => [
  for (final b in (s['bullets'] as List<Object?>?) ?? const [])
    if (b is String) '- $b',
  if (s['body'] case final String body when body.trim().isNotEmpty) body.trim(),
].join('\n');

TextElement _bodyText(Rect box, String text, DeckTheme theme, {double size = 26}) => TextElement(
  box: box,
  paragraphs: paragraphsOf(text),
  size: size,
  color: theme.text,
  lineHeight: 1.35,
  bulletColor: theme.accent,
);

List<SlideElement> _bulletSlide(String title, Map<String, Object?> s, DeckTheme theme) => [
  ..._heading(title, theme),
  _bodyText(const Rect.fromLTWH(_margin, 150, slideWidth - 2 * _margin, 350), _textOf(s), theme),
];

List<SlideElement> _sideSlide(String title, Map<String, Object?> s, DeckTheme theme, {required bool figureLeft}) {
  const gap = 32.0;
  const half = (slideWidth - 2 * _margin - gap) / 2;
  final textLeft = figureLeft ? _margin + half + gap : _margin;
  final figLeft = figureLeft ? _margin : _margin + half + gap;
  final caption = s['caption'] as String? ?? '';
  return [
    ..._heading(title, theme),
    _bodyText(Rect.fromLTWH(textLeft, 150, half, 350), _textOf(s), theme, size: 24),
    if (s['figure'] case final String ref)
      PictureElement(box: Rect.fromLTWH(figLeft, 150, half, caption.isEmpty ? 340 : 304), ref: ref),
    if (caption.isNotEmpty) _caption(Rect.fromLTWH(figLeft, 462, half, 36), caption, theme),
  ];
}

TextElement _caption(Rect box, String text, DeckTheme theme) =>
    TextElement(box: box, paragraphs: paragraphsOf(text), size: 16, color: theme.muted, align: TextAlign.center);

List<SlideElement> _figureSlide(String title, Map<String, Object?> s, DeckTheme theme) {
  final caption = s['caption'] as String? ?? '';
  return [
    if (title.isNotEmpty) ..._heading(title, theme),
    if (s['figure'] case final String ref)
      () {
        final top = title.isEmpty ? 48.0 : 146.0;
        final bottom = caption.isEmpty ? 500.0 : 476.0;
        return PictureElement(box: Rect.fromLTWH(_margin, top, slideWidth - 2 * _margin, bottom - top), ref: ref);
      }(),
    if (caption.isNotEmpty) _caption(const Rect.fromLTWH(_margin, 486, slideWidth - 2 * _margin, 32), caption, theme),
  ];
}

List<SlideElement> _backgroundSlide(String title, Map<String, Object?> s, DeckTheme theme) {
  final text = _textOf(s);
  return [
    if (s['figure'] case final String ref)
      PictureElement(box: const Rect.fromLTWH(0, 0, slideWidth, slideHeight), ref: ref, fit: PictureFit.cover),
    // A scrim so the title reads over any picture.
    ShapeElement(
      box: const Rect.fromLTWH(0, 300, slideWidth, 240),
      kind: ShapeKind.rect,
      fill: theme.background.withValues(alpha: 0.78),
    ),
    TextElement(
      box: const Rect.fromLTWH(_margin, 322, slideWidth - 2 * _margin, 120),
      paragraphs: paragraphsOf(title),
      size: 52,
      weight: FontWeight.w800,
      color: theme.title,
      lineHeight: 1.1,
      valign: VAlign.bottom,
    ),
    if (text.isNotEmpty)
      _bodyText(const Rect.fromLTWH(_margin, 450, slideWidth - 2 * _margin, 64), text, theme, size: 22),
  ];
}

List<SlideElement> _gridSlide(String title, Map<String, Object?> s, DeckTheme theme) {
  final refs = [
    for (final f in (s['figures'] as List<Object?>?) ?? const [])
      if (f is String) f,
  ].take(6).toList();
  final captions = [for (final c in (s['captions'] as List<Object?>?) ?? const []) c is String ? c : ''];
  if (refs.isEmpty) return _heading(title, theme);
  final cols = refs.length <= 3 ? refs.length : (refs.length / 2).ceil();
  final rows = (refs.length / cols).ceil();
  const gap = 24.0;
  const top = 150.0;
  final cellW = (slideWidth - 2 * _margin - gap * (cols - 1)) / cols;
  final cellH = (slideHeight - top - 40 - gap * (rows - 1)) / rows;
  return [
    ..._heading(title, theme),
    for (final (i, ref) in refs.indexed)
      ...() {
        final x = _margin + (i % cols) * (cellW + gap);
        final y = top + (i ~/ cols) * (cellH + gap);
        final caption = i < captions.length ? captions[i] : '';
        return [
          PictureElement(box: Rect.fromLTWH(x, y, cellW, caption.isEmpty ? cellH : cellH - 30), ref: ref),
          if (caption.isNotEmpty) _caption(Rect.fromLTWH(x, y + cellH - 26, cellW, 26), caption, theme),
        ];
      }(),
  ];
}

double _num(Object? v, double fallback) => switch (v) {
  final num n when n.isFinite => n.toDouble(),
  final String s => double.tryParse(s) ?? fallback,
  _ => fallback,
};

/// [preferred] when it reads on [behind], else white or near-black, whichever reads better.
Color _readableOn(Color behind, Color preferred) {
  double contrast(Color a, Color b) {
    final la = a.computeLuminance(), lb = b.computeLuminance();
    return ((la > lb ? la : lb) + 0.05) / ((la > lb ? lb : la) + 0.05);
  }

  if (contrast(preferred, behind) >= 4.5) return preferred;
  const white = Color(0xFFFFFFFF), ink = Color(0xFF16181D);
  return contrast(white, behind) >= contrast(ink, behind) ? white : ink;
}

/// One element of a slide's `elements`; null when its type is unknown or it has no size.
SlideElement? _element(Map<String, Object?> e, DeckTheme theme) {
  final box = Rect.fromLTWH(_num(e['x'], 0), _num(e['y'], 0), _num(e['w'], 0), _num(e['h'], 0));
  final rotation = _num(e['rotation'], 0);
  final opacity = _num(e['opacity'], 1).clamp(0.0, 1.0);
  final name = e['id'] as String?;
  final type = e['type'] as String? ?? 'text';
  if (box.width <= 0 && box.height <= 0) return null;
  switch (type) {
    case 'text':
      return TextElement(
        box: box,
        paragraphs: paragraphsOf(e['text'] as String? ?? ''),
        size: _num(e['size'], 24).clamp(6, 200),
        color: theme.color(e['color'], theme.text),
        weight: switch (e['weight']) {
          'light' => FontWeight.w300,
          'medium' => FontWeight.w500,
          'semibold' => FontWeight.w600,
          'bold' => FontWeight.w700,
          'black' => FontWeight.w900,
          _ => FontWeight.w400,
        },
        align: switch (e['align']) {
          'center' => TextAlign.center,
          'right' => TextAlign.right,
          _ => TextAlign.left,
        },
        valign: switch (e['valign']) {
          'middle' => VAlign.middle,
          'bottom' => VAlign.bottom,
          _ => VAlign.top,
        },
        font: switch (e['font']) {
          'serif' => SlideFont.serif,
          'mono' => SlideFont.mono,
          _ => SlideFont.sans,
        },
        fill: e['fill'] == null ? null : theme.color(e['fill'], theme.background),
        border: e['stroke'] == null ? null : theme.color(e['stroke'], theme.text),
        radius: _num(e['radius'], 0),
        padding: _num(e['padding'], e['fill'] == null ? 0 : 16),
        lineHeight: _num(e['line_height'], 1.3).clamp(0.8, 3),
        // Bullets in a box of its own follow its text unless told otherwise.
        bulletColor: e['bullet_color'] == null ? null : theme.color(e['bullet_color'], theme.accent),
        rotation: rotation,
        opacity: opacity,
        name: name,
      );
    case 'shape':
      return ShapeElement(
        box: box,
        kind: switch (e['shape']) {
          'rounded' => ShapeKind.rounded,
          'ellipse' || 'circle' => ShapeKind.ellipse,
          'line' => ShapeKind.line,
          'arrow' => ShapeKind.arrow,
          _ => ShapeKind.rect,
        },
        fill: e['fill'] == null ? null : theme.color(e['fill'], theme.accent),
        stroke: e['stroke'] == null ? null : theme.color(e['stroke'], theme.text),
        strokeWidth: _num(e['stroke_width'], e['stroke'] == null ? 0 : 2),
        radius: _num(e['radius'], 16),
        rotation: rotation,
        opacity: opacity,
        name: name,
      );
    case 'table':
      return TableElement(
        box: box,
        rows: [
          for (final r in (e['rows'] as List<Object?>?) ?? const [])
            if (r is List) [for (final c in r) c?.toString() ?? ''],
        ],
        size: _num(e['size'], 18).clamp(6, 80),
        color: theme.color(e['color'], theme.text),
        header: e['header'] as bool? ?? true,
        fill: e['fill'] == null ? null : theme.color(e['fill'], theme.background),
        headerFill: theme.color(e['header_fill'], theme.accent.withValues(alpha: 0.14)),
        headerColor: e['header_color'] == null
            ? _readableOn(
                Color.alphaBlend(
                  theme.color(e['header_fill'], theme.accent.withValues(alpha: 0.14)),
                  theme.color(e['fill'], theme.background),
                ),
                theme.color(e['color'], theme.text),
              )
            : theme.color(e['header_color'], theme.title),
        stroke: theme.color(e['stroke'], theme.text.withValues(alpha: 0.25)),
        rotation: rotation,
        opacity: opacity,
        name: name,
      );
    case 'figure' || 'image':
      final ref = (e['figure'] ?? e['image'] ?? e['ref']) as String?;
      if (ref == null || ref.isEmpty) return null;
      return PictureElement(
        box: box,
        ref: ref,
        fit: e['fit'] == 'cover' ? PictureFit.cover : PictureFit.contain,
        radius: _num(e['radius'], 0),
        rotation: rotation,
        opacity: opacity,
        name: name,
      );
  }
  return null;
}

/// Text as paragraphs: one per line, "- " lines are bullets, `**bold**` and `*italic*` become runs. Other
/// Markdown marks are dropped (slides show plain text).
List<SlideParagraph> paragraphsOf(String text) => [
  for (final raw in text.replaceAll('\r\n', '\n').split('\n'))
    if (raw.trim().isNotEmpty || text.contains('\n'))
      () {
        final bullet = RegExp(r'^\s*[-•*]\s+').hasMatch(raw);
        final line = raw
            .replaceFirst(RegExp(r'^\s*[-•*]\s+'), '')
            .replaceAll(RegExp(r'^#+\s*'), '')
            .replaceAll('`', '');
        return (runs: _runs(line), bullet: bullet);
      }(),
];

List<SlideRun> _runs(String line) {
  final out = <SlideRun>[];
  final mark = RegExp(r'\*\*(.+?)\*\*|__(.+?)__|\*(.+?)\*|_(.+?)_');
  var at = 0;
  for (final m in mark.allMatches(line)) {
    if (m.start > at) out.add((text: line.substring(at, m.start), bold: false, italic: false));
    final bold = m.group(1) ?? m.group(2);
    out.add((text: bold ?? m.group(3) ?? m.group(4)!, bold: bold != null, italic: bold == null));
    at = m.end;
  }
  if (at < line.length) out.add((text: line.substring(at), bold: false, italic: false));
  return out;
}

/// The figure and image ids a deck shows, in order, without repeats.
List<String> pictureRefsOf(List<DeckSlide> deck) => {
  for (final s in deck)
    for (final e in s.elements)
      if (e is PictureElement) e.ref,
}.toList();

/// A picture as a deck shows it: its id and the colour behind it (charts take colours that read on it).
typedef PictureUse = ({String ref, Color on});

/// Each picture a deck shows with the colour behind it, in order, without repeats.
List<PictureUse> pictureUsesOf(List<DeckSlide> deck) => {
  for (final s in deck)
    for (final e in s.elements)
      if (e is PictureElement) (ref: e.ref, on: colourBehind(s, e) ?? s.background),
}.toList();

/// The colour behind [e] on [slide]: the topmost opaque filled shape or text box under it, else the
/// slide's background; null when a picture is under it (its colours aren't known).
Color? colourBehind(DeckSlide slide, SlideElement e) {
  final index = slide.elements.indexOf(e);
  for (final under in slide.elements.take(index < 0 ? slide.elements.length : index).toList().reversed) {
    if (!under.box.overlaps(e.box)) continue;
    switch (under) {
      case PictureElement():
        return null;
      case ShapeElement(:final fill?)
          when fill.a > 0.5 && under.kind != ShapeKind.line && under.kind != ShapeKind.arrow:
        return fill;
      case TextElement(:final fill?) when fill.a > 0.5:
        return fill;
      default:
    }
  }
  return slide.background;
}
