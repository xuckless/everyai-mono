import 'dart:math' as math;

import 'package:xml/xml.dart';

/// How wide a figure is drawn in the chat (logical pixels), to judge whether its text is readable.
const _shownWidth = 600.0;

/// The smallest text, in pixels as drawn in the chat, that reads comfortably.
const _minTextPx = 9.0;

/// Above this a figure is slow to draw and costly to send back.
const _maxBytes = 150 * 1024;

/// Problems in [svg] a picture alone won't explain, as short sentences the model can act on (empty when none
/// were found). Structural only: what the figure looks like is for the model to judge from the render.
List<String> svgFindings(String svg) {
  final out = <String>[];
  if (svg.length > _maxBytes) {
    out.add('It is ${(svg.length / 1024).round()} KB; keep figures under 150 KB (fewer points, shared <defs>).');
  }
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(svg.trim());
  } on XmlException catch (e) {
    return [...out, 'It is not valid XML (${e.message}), so it may not draw at all.'];
  }
  final root = doc.rootElement;
  if (root.localName != 'svg') return [...out, 'The root element is <${root.localName}>, not <svg>.'];
  final box = _viewBox(root.getAttribute('viewBox'));
  if (box == null) out.add('The root <svg> has no valid viewBox, so it will not scale to fit.');

  final ids = <String, int>{};
  final refs = <String>{};
  final stripped = <String>{};
  final undrawn = <String>{};
  for (final e in root.descendantElements.followedBy([root])) {
    final id = e.getAttribute('id');
    if (id != null && id.isNotEmpty) ids[id] = (ids[id] ?? 0) + 1;
    switch (e.localName) {
      case 'script' || 'foreignObject' || 'iframe':
        stripped.add('<${e.localName}>');
      case final name when _notDrawn.containsKey(name):
        undrawn.add(name);
    }
    for (final a in ['marker-start', 'marker-mid', 'marker-end', 'filter']) {
      if (e.getAttribute(a) != null || (e.getAttribute('style')?.contains('$a:') ?? false)) {
        undrawn.add(a.startsWith('marker') ? 'marker' : 'filter');
      }
    }
    for (final a in e.attributes) {
      final v = a.value;
      if (a.name.local == 'href' || a.name.qualified == 'xlink:href') {
        if (v.startsWith('#')) {
          refs.add(v.substring(1));
        } else if (v.isNotEmpty) {
          stripped.add('links to other files ($v)');
        }
      }
      if (a.name.local.startsWith('on')) stripped.add('event handlers (${a.name.local})');
      for (final m in RegExp(r'url\(\s*["\x27]?#([^)"\x27\s]+)').allMatches(v)) {
        refs.add(m.group(1)!);
      }
    }
  }
  for (final e in ids.entries) {
    if (e.value > 1) out.add('The id "${e.key}" is used ${e.value} times; ids must be unique.');
  }
  for (final r in refs) {
    if (!ids.containsKey(r)) out.add('Something points at #$r, which is not defined, so it draws without it.');
  }
  if (stripped.isNotEmpty) out.add('The app removes ${stripped.join(', ')} before drawing.');
  for (final name in undrawn) {
    out.add(_notDrawn[name]!);
  }

  if (box == null) return out;
  final background = _backgroundOf(root, box);
  final scale = _shownWidth / box.width;
  var tiny = 0;
  final offCanvas = <String>[];
  final overflowing = <String>[];
  final faint = <String>[];
  // Paint order matters: a filled shape drawn after a line hides it under a label.
  final texts = <({String text, _Box box, int order})>[];
  final strokes = <({(double, double, double, double) seg, int order})>[];
  final covers = <({_Box box, int order})>[];
  var order = 0;
  for (final e in root.descendantElements) {
    order++;
    if (_transformed(e)) continue;
    final name = e.localName;
    final label = _label(e);
    if (name == 'text') {
      final size = _fontSize(e);
      final text = e.innerText.trim();
      if (text.isEmpty) continue;
      if (size * scale < _minTextPx) tiny++;
      final x = _num(e.getAttribute('x')) ?? 0;
      final y = _num(e.getAttribute('y')) ?? 0;
      final width = 0.56 * size * text.length;
      final anchor = _inherited(e, 'text-anchor') ?? 'start';
      final (left, right) = switch (anchor) {
        'middle' => (x - width / 2, x + width / 2),
        'end' => (x - width, x),
        _ => (x, x + width),
      };
      texts.add((text: text, box: (x: left, y: y - size * 0.8, width: right - left, height: size), order: order));
      if (y < box.y || y - size > box.bottom || right < box.x || left > box.right) {
        offCanvas.add(label);
      } else if (left < box.x - 1 || right > box.right + 1) {
        overflowing.add(_short(text));
      }
      final fill = _color(_inherited(e, 'fill') ?? '#000');
      if (fill != null && background != null && _contrast(fill, background) < 3) {
        faint.add(_short(text));
      }
      continue;
    }
    if (name == 'line') {
      final l = _line(e)!;
      final x1 = _num(e.getAttribute('x1')) ?? 0, y1 = _num(e.getAttribute('y1')) ?? 0;
      final x2 = _num(e.getAttribute('x2')) ?? 0, y2 = _num(e.getAttribute('y2')) ?? 0;
      strokes.add((seg: (x1, y1, x2, y2), order: order));
      if (!l.overlaps(box)) offCanvas.add(label);
      continue;
    }
    if (name == 'path' || name == 'polyline') {
      strokes.addAll([for (final seg in _segments(e)) (seg: seg, order: order)]);
    }
    final bounds = switch (name) {
      'rect' || 'image' || 'use' => _rect(e),
      'circle' => _circle(e, 'r', 'r'),
      'ellipse' => _circle(e, 'rx', 'ry'),
      'line' => _line(e),
      _ => null,
    };
    if (bounds != null && !bounds.overlaps(box)) offCanvas.add(label);
    final fill = _inherited(e, 'fill');
    if (bounds != null && name != 'line' && fill != 'none' && fill != 'transparent') {
      covers.add((box: bounds, order: order));
    }
  }
  final overlapping = <String>[];
  for (var i = 0; i < texts.length; i++) {
    for (var j = i + 1; j < texts.length; j++) {
      final a = texts[i], b = texts[j];
      if (_shrink(a.box).overlaps(_shrink(b.box))) overlapping.add('${_short(a.text)} and ${_short(b.text)}');
    }
  }
  if (overlapping.isNotEmpty) out.add('Text overlaps other text: ${_some(overlapping)}. Move one of each pair.');
  final crossed = <String>{
    for (final t in texts)
      for (final s in strokes)
        if (_crosses(s.seg, _shrink(t.box)) && !_hidden(s.order, t, covers)) _short(t.text),
  };
  if (crossed.isNotEmpty) {
    out.add(
      'A line or arrow runs through text: ${_some(crossed.toList())}. Route it around, or put the label clear of it.',
    );
  }
  if (tiny > 0) {
    out.add('$tiny text element(s) are under ${_minTextPx.round()} px when shown in the chat; enlarge them.');
  }
  if (overflowing.isNotEmpty) {
    out.add('Text likely runs past the edge of the viewBox: ${_some(overflowing)}. Shorten, wrap or move it.');
  }
  if (offCanvas.isNotEmpty) out.add('Outside the viewBox, so never seen: ${_some(offCanvas)}.');
  if (faint.isNotEmpty) out.add('Text with too little contrast against the background: ${_some(faint)}.');
  return out;
}

String _some(List<String> items) =>
    items.length <= 4 ? items.join(', ') : '${items.take(4).join(', ')} and ${items.length - 4} more';

String _label(XmlElement e) => switch (e.getAttribute('id')) {
  final String id when id.isNotEmpty => '<${e.localName} id="$id">',
  _ => '<${e.localName}>',
};

typedef _Box = ({double x, double y, double width, double height});

extension on _Box {
  double get right => x + width;
  double get bottom => y + height;
  bool overlaps(_Box o) => x < o.right && right > o.x && y < o.bottom && bottom > o.y;
}

_Box? _viewBox(String? raw) {
  final parts = raw?.trim().split(RegExp(r'[\s,]+')).map(double.tryParse).toList();
  if (parts == null || parts.length != 4 || parts.any((p) => p == null)) return null;
  final [x, y, w, h] = parts.cast<double>();
  if (w <= 0 || h <= 0) return null;
  return (x: x, y: y, width: w, height: h);
}

double? _num(String? raw) => raw == null ? null : double.tryParse(raw.trim().replaceFirst(RegExp(r'px$'), ''));

bool _transformed(XmlElement e) {
  for (XmlNode? n = e; n is XmlElement; n = n.parent) {
    if (n.getAttribute('transform') != null) return true;
    if (n.localName == 'defs' || n.localName == 'symbol' || n.localName == 'clipPath' || n.localName == 'mask') {
      return true;
    }
    // A nested <svg> has its own coordinates.
    if (n.localName == 'svg' && n.parent is XmlElement) return true;
  }
  return false;
}

/// A presentation property on [e] or its ancestors (attribute or inline style).
String? _inherited(XmlElement e, String property) {
  for (XmlNode? n = e; n is XmlElement; n = n.parent) {
    final style = n.getAttribute('style');
    if (style != null) {
      final m = RegExp('(?:^|;)\\s*$property\\s*:\\s*([^;]+)').firstMatch(style);
      if (m != null) return m.group(1)!.trim();
    }
    if (n.getAttribute(property) case final String v) return v.trim();
  }
  return null;
}

double _fontSize(XmlElement e) => _num(_inherited(e, 'font-size')) ?? 16;

_Box? _rect(XmlElement e) {
  final w = _num(e.getAttribute('width'));
  final h = _num(e.getAttribute('height'));
  if (w == null || h == null) return null;
  return (x: _num(e.getAttribute('x')) ?? 0, y: _num(e.getAttribute('y')) ?? 0, width: w, height: h);
}

_Box? _circle(XmlElement e, String rx, String ry) {
  final a = _num(e.getAttribute(rx));
  final b = _num(e.getAttribute(ry)) ?? a;
  if (a == null || b == null) return null;
  final cx = _num(e.getAttribute('cx')) ?? 0;
  final cy = _num(e.getAttribute('cy')) ?? 0;
  return (x: cx - a, y: cy - b, width: 2 * a, height: 2 * b);
}

_Box? _line(XmlElement e) {
  final x1 = _num(e.getAttribute('x1')) ?? 0, x2 = _num(e.getAttribute('x2')) ?? 0;
  final y1 = _num(e.getAttribute('y1')) ?? 0, y2 = _num(e.getAttribute('y2')) ?? 0;
  return (
    x: math.min(x1, x2),
    y: math.min(y1, y2),
    width: math.max((x1 - x2).abs(), 0.01),
    height: math.max((y1 - y2).abs(), 0.01),
  );
}

/// The colour behind the figure: a rect covering the viewBox drawn first, else white (the app draws on white or
/// the chat's card).
int? _backgroundOf(XmlElement root, _Box box) {
  for (final e in root.childElements) {
    if (e.localName == 'defs' || e.localName == 'style' || e.localName == 'title') continue;
    final r = e.localName == 'rect' ? _rect(e) : null;
    if (r != null && r.width >= box.width * .95 && r.height >= box.height * .95) {
      return _color(_inherited(e, 'fill') ?? '#000');
    }
    break;
  }
  return 0xFFFFFF;
}

/// An RGB colour from #rgb, #rrggbb or a few names; null for gradients, `none` and the rest.
int? _color(String raw) {
  final v = raw.trim().toLowerCase();
  switch (v) {
    case 'white':
      return 0xFFFFFF;
    case 'black':
      return 0x000000;
  }
  final hex = RegExp(r'^#([0-9a-f]{3}|[0-9a-f]{6})$').firstMatch(v)?.group(1);
  if (hex == null) return null;
  final full = hex.length == 3 ? hex.split('').map((c) => '$c$c').join() : hex;
  return int.parse(full, radix: 16);
}

double _luminance(int rgb) {
  double channel(int c) {
    final s = c / 255;
    return s <= 0.03928 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * channel(rgb >> 16 & 0xFF) + 0.7152 * channel(rgb >> 8 & 0xFF) + 0.0722 * channel(rgb & 0xFF);
}

/// The WCAG contrast ratio of two colours (1 to 21).
double _contrast(int a, int b) {
  final la = _luminance(a), lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// SVG features the app's renderer does not draw, and what to do instead.
const _notDrawn = {
  'marker': '<marker> arrowheads are not drawn by the app: draw each arrowhead as a small <path> or <polygon>.',
  'filter': 'Filters (blur, drop shadows) are not drawn by the app: fake a shadow with an offset, darker shape.',
  'textPath': '<textPath> is not drawn by the app: place plain <text> (rotate it if needed).',
  'animate': 'Animation is not shown by the app (it draws one still frame).',
  'animateTransform': 'Animation is not shown by the app (it draws one still frame).',
  'animateMotion': 'Animation is not shown by the app (it draws one still frame).',
  'set': 'Animation is not shown by the app (it draws one still frame).',
};

String _short(String text) => '"${text.length > 24 ? '${text.substring(0, 24)}…' : text}"';

/// A text box made a little smaller, so glyphs that merely touch don't count as overlapping.
_Box _shrink(_Box b) =>
    (x: b.x + b.width * 0.08, y: b.y + b.height * 0.2, width: b.width * 0.84, height: b.height * 0.6);

/// The straight segments of a path made only of absolute M/L/H/V/Z commands, or of a polyline; curves and
/// relative commands are skipped (their shape can't be known without drawing them).
List<(double, double, double, double)> _segments(XmlElement e) {
  final out = <(double, double, double, double)>[];
  if (e.localName == 'polyline') {
    final n = RegExp(r'-?[\d.]+(?:e-?\d+)?')
        .allMatches(e.getAttribute('points') ?? '')
        .map((m) => double.parse(m.group(0)!))
        .toList();
    for (var i = 0; i + 3 < n.length; i += 2) {
      out.add((n[i], n[i + 1], n[i + 2], n[i + 3]));
    }
    return out;
  }
  final d = e.getAttribute('d') ?? '';
  if (RegExp('[a-zA-Z]').allMatches(d).any((m) => !'MLHVZ'.contains(m.group(0)!))) return out;
  var x = 0.0, y = 0.0;
  var started = false;
  for (final m in RegExp(r'([MLHVZ])([^MLHVZ]*)').allMatches(d)) {
    final n = RegExp(r'-?[\d.]+(?:e-?\d+)?').allMatches(m.group(2)!).map((v) => double.parse(v.group(0)!)).toList();
    switch (m.group(1)) {
      case 'M' when n.length >= 2:
        (x, y, started) = (n[0], n[1], true);
      case 'L' when n.length >= 2 && started:
        for (var i = 0; i + 1 < n.length; i += 2) {
          out.add((x, y, n[i], n[i + 1]));
          (x, y) = (n[i], n[i + 1]);
        }
      case 'H' when n.isNotEmpty && started:
        out.add((x, y, n.last, y));
        x = n.last;
      case 'V' when n.isNotEmpty && started:
        out.add((x, y, x, n.last));
        y = n.last;
    }
  }
  return out;
}

/// Whether a filled shape drawn after the line (and before the label) covers the label, hiding the line there.
bool _hidden(int line, ({String text, _Box box, int order}) t, List<({_Box box, int order})> covers) {
  final b = _shrink(t.box);
  return covers.any(
    (c) =>
        c.order > line &&
        c.order < t.order &&
        c.box.x <= b.x &&
        c.box.y <= b.y &&
        c.box.right >= b.right &&
        c.box.bottom >= b.bottom,
  );
}

/// Whether segment [s] passes through box [b] (Liang–Barsky clipping).
bool _crosses((double, double, double, double) s, _Box b) {
  final (x1, y1, x2, y2) = s;
  final dx = x2 - x1, dy = y2 - y1;
  var t0 = 0.0, t1 = 1.0;
  for (final (p, q) in [(-dx, x1 - b.x), (dx, b.right - x1), (-dy, y1 - b.y), (dy, b.bottom - y1)]) {
    if (p == 0) {
      if (q < 0) return false;
    } else {
      final r = q / p;
      if (p < 0) {
        if (r > t1) return false;
        if (r > t0) t0 = r;
      } else {
        if (r < t0) return false;
        if (r < t1) t1 = r;
      }
    }
  }
  return t0 <= t1;
}
