import 'dart:math' as math;
import 'dart:ui';

import 'package:xml/xml.dart';

/// A part of an SVG figure the user can point at: its box in viewBox units, the id the model can edit it by (its
/// own or its nearest ancestor's), and a short description.
typedef SvgPart = ({Rect box, String? id, String label, int depth});

/// The figure's viewBox, or null.
Rect? svgViewBox(String svg) {
  final m = RegExp(r'''viewBox\s*=\s*["']([^"']+)["']''').firstMatch(svg);
  final n = m?.group(1)?.trim().split(RegExp(r'[\s,]+')).map(double.tryParse).toList();
  if (n == null || n.length != 4 || n.any((v) => v == null) || n[2]! <= 0 || n[3]! <= 0) return null;
  return Rect.fromLTWH(n[0]!, n[1]!, n[2]!, n[3]!);
}

/// The figure's parts with their boxes, outermost first. Boxes follow translate and scale transforms; parts under
/// other transforms take their group's box. Paths are boxed by their absolute coordinates only.
List<SvgPart> svgParts(String svg) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(svg.trim());
  } on XmlException {
    return const [];
  }
  final out = <SvgPart>[];
  Rect? walk(XmlElement e, Offset shift, double scale, String? inherited, int depth) {
    if (const {
      'defs',
      'clipPath',
      'mask',
      'marker',
      'symbol',
      'style',
      'title',
      'desc',
      'linearGradient',
      'radialGradient',
      'pattern',
      'filter',
    }.contains(e.localName)) {
      return null;
    }
    var s = shift;
    var k = scale;
    if (e.getAttribute('transform') case final t?) {
      final translate = RegExp(r'translate\(\s*([-\d.e]+)[\s,]*([-\d.e]*)\s*\)').firstMatch(t);
      final sc = RegExp(r'scale\(\s*([-\d.e]+)').firstMatch(t);
      if (translate != null) {
        s += Offset(double.parse(translate.group(1)!), double.tryParse(translate.group(2) ?? '') ?? 0) * k;
      }
      if (sc != null) k *= double.parse(sc.group(1)!);
    }
    final id = e.getAttribute('id');
    final named = (id != null && id.isNotEmpty) ? id : inherited;
    Rect? own = _box(e);
    if (own != null) own = Rect.fromLTWH(s.dx + own.left * k, s.dy + own.top * k, own.width * k, own.height * k);
    Rect? children;
    for (final c in e.childElements) {
      final b = walk(c, s, k, named, depth + 1);
      if (b != null) children = children?.expandToInclude(b) ?? b;
    }
    final box = own ?? children;
    if (box != null && e.localName != 'svg') {
      final text = e.localName == 'text' ? e.innerText.trim() : '';
      out.add((
        box: box,
        id: named,
        label: text.isNotEmpty
            ? '"${text.length > 30 ? '${text.substring(0, 30)}…' : text}"'
            : (id != null && id.isNotEmpty ? '#$id' : '<${e.localName}>'),
        depth: depth,
      ));
    }
    return box;
  }

  walk(doc.rootElement, Offset.zero, 1, null, 0);
  return out;
}

/// The part under [point] (viewBox units): the smallest box that holds it, the deepest on a tie.
SvgPart? partAt(List<SvgPart> parts, Offset point) {
  SvgPart? best;
  for (final p in parts) {
    if (!p.box.inflate(2).contains(point)) continue;
    final area = p.box.width * p.box.height;
    if (best == null ||
        area < best.box.width * best.box.height ||
        (area == best.box.width * best.box.height && p.depth > best.depth)) {
      best = p;
    }
  }
  return best;
}

double? _n(XmlElement e, String name) => double.tryParse((e.getAttribute(name) ?? '').replaceFirst('px', ''));

Rect? _box(XmlElement e) {
  switch (e.localName) {
    case 'rect' || 'image' || 'use' || 'foreignObject':
      final w = _n(e, 'width'), h = _n(e, 'height');
      if (w == null || h == null) return null;
      return Rect.fromLTWH(_n(e, 'x') ?? 0, _n(e, 'y') ?? 0, w, h);
    case 'circle':
      final r = _n(e, 'r');
      if (r == null) return null;
      return Rect.fromCircle(center: Offset(_n(e, 'cx') ?? 0, _n(e, 'cy') ?? 0), radius: r);
    case 'ellipse':
      final rx = _n(e, 'rx'), ry = _n(e, 'ry');
      if (rx == null || ry == null) return null;
      return Rect.fromCenter(center: Offset(_n(e, 'cx') ?? 0, _n(e, 'cy') ?? 0), width: 2 * rx, height: 2 * ry);
    case 'line':
      return Rect.fromPoints(Offset(_n(e, 'x1') ?? 0, _n(e, 'y1') ?? 0), Offset(_n(e, 'x2') ?? 0, _n(e, 'y2') ?? 0));
    case 'text':
      final size =
          double.tryParse(
            RegExp(r'font-size\s*:\s*([\d.]+)').firstMatch(e.getAttribute('style') ?? '')?.group(1) ??
                (e.getAttribute('font-size') ?? '16').replaceFirst('px', ''),
          ) ??
          16;
      final width = 0.56 * size * e.innerText.trim().length;
      final x = _n(e, 'x') ?? 0, y = _n(e, 'y') ?? 0;
      final left = switch (e.getAttribute('text-anchor')) {
        'middle' => x - width / 2,
        'end' => x - width,
        _ => x,
      };
      return Rect.fromLTWH(left, y - size * 0.8, width, size);
    case 'polygon' || 'polyline':
      return _points(e.getAttribute('points') ?? '');
    case 'path':
      final d = e.getAttribute('d') ?? '';
      // Relative commands move from where the pen is; only absolute coordinates are boxed.
      if (RegExp('[a-z]').hasMatch(d.replaceAll(RegExp('e-?[0-9]'), ''))) return null;
      return _points(d.replaceAll(RegExp('[A-Za-z]'), ' '));
  }
  return null;
}

Rect? _points(String text) {
  final n = RegExp(r'-?\d*\.?\d+(?:e-?\d+)?').allMatches(text).map((m) => double.parse(m.group(0)!)).toList();
  if (n.length < 2) return null;
  var (minX, minY, maxX, maxY) = (double.infinity, double.infinity, -double.infinity, -double.infinity);
  for (var i = 0; i + 1 < n.length; i += 2) {
    minX = math.min(minX, n[i]);
    maxX = math.max(maxX, n[i]);
    minY = math.min(minY, n[i + 1]);
    maxY = math.max(maxY, n[i + 1]);
  }
  return Rect.fromLTRB(minX, minY, maxX, maxY);
}

/// The distinct colours an SVG uses in fill and stroke (`#rgb` or `#rrggbb`, lower case), most used first.
List<String> svgColours(String svg) {
  final counts = <String, int>{};
  for (final m in RegExp(
    r'''(?:fill|stroke|stop-color)\s*[=:]\s*["']?\s*(#[0-9a-fA-F]{6}\b|#[0-9a-fA-F]{3}\b)''',
  ).allMatches(svg)) {
    final c = m.group(1)!.toLowerCase();
    counts[c] = (counts[c] ?? 0) + 1;
  }
  return (counts.keys.toList()..sort((a, b) => counts[b]!.compareTo(counts[a]!)));
}

/// The text of each `<text>` element, in order (the editor's fields).
List<String> svgTexts(String svg) => [
  for (final m in RegExp(r'<text\b[^>]*>([^<]*)</text>').allMatches(svg))
    if (m.group(1)!.trim().isNotEmpty) m.group(1)!,
];

/// [svg] with every use of each colour in [colours] replaced (old → new), and the n-th `<text>` element's text in
/// [texts] replaced (index → new text). Text is escaped.
String editSvg(String svg, {Map<String, String> colours = const {}, Map<int, String> texts = const {}}) {
  var out = svg;
  if (colours.isNotEmpty) {
    out = out.replaceAllMapped(
      RegExp(r'''((?:fill|stroke|stop-color)\s*[=:]\s*["']?\s*)(#[0-9a-fA-F]{6}\b|#[0-9a-fA-F]{3}\b)'''),
      (m) => '${m.group(1)}${colours[m.group(2)!.toLowerCase()] ?? m.group(2)}',
    );
  }
  if (texts.isNotEmpty) {
    var i = -1;
    out = out.replaceAllMapped(RegExp(r'(<text\b[^>]*>)([^<]*)(</text>)'), (m) {
      if (m.group(2)!.trim().isEmpty) return m.group(0)!;
      i++;
      final replacement = texts[i];
      if (replacement == null) return m.group(0)!;
      final escaped = replacement.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
      return '${m.group(1)}$escaped${m.group(3)}';
    });
  }
  return out;
}
