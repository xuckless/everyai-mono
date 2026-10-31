import 'dart:math' as math;

import '../domain/chart_spec.dart';

// A chart as a self-contained SVG on white, for PDF and Word downloads (via
// the SVG rasterizer) and the chart's SVG download. Same spec, colors and
// rules as the app's fl_chart view; laid out for print.

const _width = 640.0;
const _font = "font-family=\"'Noto Sans', 'Helvetica Neue', Arial, sans-serif\"";
const _ink = '#1C1C1E', _muted = '#636368', _grid = '#E5E5EA';

String _hex(int argb) => '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

String _color(int i) => _hex(chartPalette[i % chartPalette.length]);

String _esc(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

String _n(double v) => v.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');

/// [s] cut to about [width] points of 12 pt text.
String _fit(String s, double width, {double size = 11}) {
  final max = math.max(3, (width / (size * 0.56)).floor());
  return s.length <= max ? s : '${s.substring(0, max - 1)}…';
}

/// [text] broken into lines of about [width] points.
List<String> _wrap(String text, double width, {double size = 12}) {
  final max = math.max(10, (width / (size * 0.53)).floor());
  final lines = <String>[];
  var line = '';
  for (final word in text.split(RegExp(r'\s+'))) {
    if (word.isEmpty) continue;
    if (line.isEmpty) {
      line = word;
    } else if (line.length + 1 + word.length <= max) {
      line = '$line $word';
    } else {
      lines.add(line);
      line = word;
    }
  }
  if (line.isNotEmpty) lines.add(line);
  return lines;
}

/// Round axis ticks covering [lo]..[hi].
List<double> niceTicks(double lo, double hi, {int count = 5}) {
  final range = hi - lo;
  final raw = range / count;
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final step = [1, 2, 2.5, 5, 10].map((m) => m * mag).firstWhere((s) => s >= raw, orElse: () => 10 * mag);
  final start = (lo / step).floor() * step;
  final end = (hi / step).ceil() * step;
  return [for (var v = start; v <= end + step / 2; v += step) double.parse(v.toStringAsFixed(10))];
}

/// [spec] drawn as SVG; null when it has no data.
String? chartSvg(ChartSpec spec) {
  if (spec.isEmpty) return null;
  final out = StringBuffer();
  var y = 16.0;
  if (spec.title.isNotEmpty) {
    y += 16;
    out.writeln('<text x="20" y="${_n(y)}" font-size="16" font-weight="600" fill="$_ink">${_esc(spec.title)}</text>');
    y += 10;
  }
  if (spec.isRound) {
    y = _round(out, spec, y);
  } else {
    if (spec.series.length > 1) y = _legend(out, spec, y);
    y = _cartesian(out, spec, y);
  }
  // Caption and source.
  y += 6;
  for (final line in _wrap(spec.caption, _width - 40)) {
    y += 16;
    out.writeln('<text x="20" y="${_n(y)}" font-size="12" fill="$_ink">${_esc(line)}</text>');
  }
  if (spec.source.isNotEmpty) {
    for (final line in _wrap('Source: ${spec.source}', _width - 40, size: 11)) {
      y += 15;
      out.writeln('<text x="20" y="${_n(y)}" font-size="11" fill="$_muted">${_esc(line)}</text>');
    }
  }
  y += 16;
  return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${_n(_width)} ${_n(y)}" $_font>\n'
      '<rect width="100%" height="100%" fill="#FFFFFF"/>\n$out</svg>';
}

double _legend(StringBuffer out, ChartSpec spec, double top) {
  var x = 20.0, y = top + 12;
  for (final (i, _) in spec.series.indexed) {
    final name = _fit(spec.seriesName(i), 160);
    final w = 18 + name.length * 6.6 + 16;
    if (x + w > _width - 20) {
      x = 20;
      y += 18;
    }
    out
      ..writeln('<rect x="${_n(x)}" y="${_n(y - 9)}" width="10" height="10" rx="2" fill="${_color(i)}"/>')
      ..writeln('<text x="${_n(x + 15)}" y="${_n(y)}" font-size="12" fill="$_ink">${_esc(name)}</text>');
    x += w;
  }
  return y + 10;
}

double _cartesian(StringBuffer out, ChartSpec spec, double top) {
  final horizontal = spec.type == ChartType.bar && spec.horizontal;
  final cats = spec.categories;
  final (lo0, hi0) = spec.valueRange;
  final ticks = niceTicks(lo0, hi0);
  final lo = ticks.first, hi = ticks.last;

  // Numeric x for lines, areas and scatter with number x values.
  final numericX = !spec.categorical;
  var xlo = 0.0, xhi = 1.0;
  List<double> xticks = const [];
  if (numericX) {
    final xs = [
      for (final s in spec.series)
        for (final p in s.points) (p.x as num).toDouble(),
    ];
    xlo = xs.reduce(math.min);
    xhi = xs.reduce(math.max);
    if (xlo == xhi) xhi = xlo + 1;
    xticks = niceTicks(xlo, xhi, count: 6).where((t) => t >= xlo - 1e-9 && t <= xhi + 1e-9).toList();
  }

  final catLabelWidth = horizontal ? math.min(170.0, 14 + cats.fold(0, (m, c) => math.max(m, c.length)) * 6.4) : 0.0;
  final double left = 20 + (spec.yLabel.isNotEmpty && !horizontal ? 18 : 0) + (horizontal ? catLabelWidth : 48);
  final right = _width - 24;
  final plotTop = top + (horizontal && spec.referenceLines.isNotEmpty ? 24 : 14);
  final plotHeight = horizontal ? math.max(160.0, cats.length * 30.0) : 280.0;
  final plotBottom = plotTop + plotHeight;
  final plotW = right - left;

  // Value axis position.
  double vPos(double v) =>
      horizontal ? left + (v - lo) / (hi - lo) * plotW : plotBottom - (v - lo) / (hi - lo) * plotHeight;
  final band = (horizontal ? plotHeight : plotW) / math.max(1, cats.length);
  double catCenter(int i) => (horizontal ? plotTop : left) + band * (i + 0.5);
  double xPos(Object x) {
    if (numericX) return left + ((x as num).toDouble() - xlo) / (xhi - xlo) * plotW;
    final i = cats.indexOf(xText(x));
    return i < 0 ? double.nan : catCenter(i);
  }

  // Grid and value labels.
  for (final t in ticks) {
    final p = vPos(t);
    if (horizontal) {
      out
        ..writeln('<line x1="${_n(p)}" y1="${_n(plotTop)}" x2="${_n(p)}" y2="${_n(plotBottom)}" stroke="$_grid"/>')
        ..writeln(
          '<text x="${_n(p)}" y="${_n(plotBottom + 16)}" font-size="11" fill="$_muted" text-anchor="middle">'
          '${_esc(spec.format(t))}</text>',
        );
    } else {
      out
        ..writeln('<line x1="${_n(left)}" y1="${_n(p)}" x2="${_n(right)}" y2="${_n(p)}" stroke="$_grid"/>')
        ..writeln(
          '<text x="${_n(left - 6)}" y="${_n(p + 4)}" font-size="11" fill="$_muted" text-anchor="end">'
          '${_esc(spec.format(t))}</text>',
        );
    }
  }

  // Category or numeric x labels.
  if (numericX) {
    for (final t in xticks) {
      out.writeln(
        '<text x="${_n(xPos(t))}" y="${_n(plotBottom + 16)}" font-size="11" fill="$_muted" text-anchor="middle">'
        '${_esc(formatNumber(t))}</text>',
      );
    }
  } else {
    final every = horizontal ? 1 : math.max(1, (cats.length * 46 / plotW).ceil());
    for (final (i, c) in cats.indexed) {
      if (i % every != 0) continue;
      if (horizontal) {
        out.writeln(
          '<text x="${_n(left - 8)}" y="${_n(catCenter(i) + 4)}" font-size="11" fill="$_ink" text-anchor="end">'
          '${_esc(_fit(c, catLabelWidth - 10))}</text>',
        );
      } else {
        out.writeln(
          '<text x="${_n(catCenter(i))}" y="${_n(plotBottom + 16)}" font-size="11" fill="$_muted" '
          'text-anchor="middle">${_esc(_fit(c, band * every - 4))}</text>',
        );
      }
    }
  }

  // The zero line.
  if (lo < 0 && hi > 0) {
    final z = vPos(0);
    out.writeln(
      horizontal
          ? '<line x1="${_n(z)}" y1="${_n(plotTop)}" x2="${_n(z)}" y2="${_n(plotBottom)}" stroke="$_muted"/>'
          : '<line x1="${_n(left)}" y1="${_n(z)}" x2="${_n(right)}" y2="${_n(z)}" stroke="$_muted"/>',
    );
  }

  switch (spec.type) {
    case ChartType.bar:
      final n = spec.series.length;
      for (final (ci, c) in cats.indexed) {
        var up = 0.0, down = 0.0;
        for (final (si, s) in spec.series.indexed) {
          final v = spec.valueAt(s, c);
          if (v == null) continue;
          final double from, to, offset, thickness;
          if (spec.stacked) {
            from = v >= 0 ? up : down;
            to = from + v;
            if (v >= 0) {
              up = to;
            } else {
              down = to;
            }
            thickness = band * 0.6;
            offset = -thickness / 2;
          } else {
            from = 0;
            to = v;
            thickness = band * 0.72 / n;
            offset = -band * 0.36 + si * thickness;
          }
          final a = vPos(from), b = vPos(to);
          final gap = spec.stacked || n == 1 ? 0.0 : 1.0;
          final rect = horizontal
              ? 'x="${_n(math.min(a, b))}" y="${_n(catCenter(ci) + offset + gap)}" '
                    'width="${_n((b - a).abs())}" height="${_n(thickness - 2 * gap)}"'
              : 'x="${_n(catCenter(ci) + offset + gap)}" y="${_n(math.min(a, b))}" '
                    'width="${_n(thickness - 2 * gap)}" height="${_n((b - a).abs())}"';
          out.writeln('<rect $rect rx="${spec.stacked ? 0 : 2}" fill="${_color(si)}"/>');
        }
      }
    case ChartType.scatter:
      for (final (si, s) in spec.series.indexed) {
        for (final p in s.points) {
          final x = xPos(p.x);
          if (x.isNaN) continue;
          out.writeln('<circle cx="${_n(x)}" cy="${_n(vPos(p.y))}" r="4" fill="${_color(si)}" fill-opacity="0.85"/>');
        }
      }
    case ChartType.line || ChartType.area || ChartType.pie || ChartType.donut:
      for (final (si, s) in spec.series.indexed) {
        final pts = [
          for (final p in s.points)
            if (!xPos(p.x).isNaN) (xPos(p.x), vPos(p.y)),
        ];
        if (!spec.categorical) pts.sort((a, b) => a.$1.compareTo(b.$1));
        if (pts.isEmpty) continue;
        final line = [for (final (i, (x, y)) in pts.indexed) '${i == 0 ? 'M' : 'L'}${_n(x)} ${_n(y)}'].join(' ');
        if (spec.type == ChartType.area) {
          final base = vPos(math.max(lo, math.min(0, hi)));
          out.writeln(
            '<path d="$line L${_n(pts.last.$1)} ${_n(base)} L${_n(pts.first.$1)} ${_n(base)} Z" '
            'fill="${_color(si)}" fill-opacity="0.18"/>',
          );
        }
        out.writeln(
          '<path d="$line" fill="none" stroke="${_color(si)}" stroke-width="2.5" stroke-linejoin="round" '
          'stroke-linecap="round"/>',
        );
        if (pts.length <= 24) {
          for (final (x, y) in pts) {
            out.writeln(
              '<circle cx="${_n(x)}" cy="${_n(y)}" r="3" fill="#FFFFFF" stroke="${_color(si)}" stroke-width="2"/>',
            );
          }
        }
      }
  }

  // Reference lines: a value across the chart.
  for (final r in spec.referenceLines) {
    final p = vPos(r.y);
    final label = _esc(r.label.isEmpty ? spec.format(r.y) : '${r.label} (${spec.format(r.y)})');
    out.writeln(
      horizontal
          ? '<line x1="${_n(p)}" y1="${_n(plotTop)}" x2="${_n(p)}" y2="${_n(plotBottom)}" stroke="$_ink" '
                'stroke-width="1.2" stroke-dasharray="5 4"/>\n'
                '<text x="${_n(p + 4)}" y="${_n(plotTop - 3)}" font-size="11" fill="$_ink">$label</text>'
          : '<line x1="${_n(left)}" y1="${_n(p)}" x2="${_n(right)}" y2="${_n(p)}" stroke="$_ink" '
                'stroke-width="1.2" stroke-dasharray="5 4"/>\n'
                '<text x="${_n(right)}" y="${_n(p - 5)}" font-size="11" fill="$_ink" text-anchor="end">$label</text>',
    );
  }

  // Annotations: a marked x (an event, a peak).
  for (final (i, a) in spec.annotations.indexed) {
    final x = horizontal ? double.nan : xPos(a.x);
    if (x.isNaN) continue;
    final ly = plotTop + 10 + (i % 2) * 14;
    final anchor = x > right - 80 ? 'end' : (x < left + 80 ? 'start' : 'middle');
    out
      ..writeln(
        '<line x1="${_n(x)}" y1="${_n(ly + 4)}" x2="${_n(x)}" y2="${_n(plotBottom)}" stroke="$_muted" '
        'stroke-dasharray="3 3"/>',
      )
      ..writeln(
        '<text x="${_n(x)}" y="${_n(ly)}" font-size="11" fill="$_ink" text-anchor="$anchor">'
        '${_esc(_fit(a.label, 150))}</text>',
      );
  }

  var bottom = plotBottom + 22;
  final xLabel = horizontal ? spec.yLabel : spec.xLabel;
  if (xLabel.isNotEmpty) {
    bottom += 14;
    out.writeln(
      '<text x="${_n(left + plotW / 2)}" y="${_n(bottom)}" font-size="12" fill="$_muted" text-anchor="middle">'
      '${_esc(xLabel)}</text>',
    );
  }
  if (!horizontal && spec.yLabel.isNotEmpty) {
    final cy = plotTop + plotHeight / 2;
    out.writeln(
      '<text x="26" y="${_n(cy)}" font-size="12" fill="$_muted" text-anchor="middle" '
      'transform="rotate(-90 26 ${_n(cy)})">${_esc(spec.yLabel)}</text>',
    );
  }
  return bottom;
}

double _round(StringBuffer out, ChartSpec spec, double top) {
  final slices = spec.slices;
  final total = slices.fold(0.0, (t, s) => t + s.value);
  const r = 120.0;
  final cx = 20 + r + 10, cy = top + 12 + r;
  final inner = spec.type == ChartType.donut ? r * 0.58 : 0.0;
  String colorOf(int i) => slices[i].other ? _hex(chartOtherColor) : _color(i);
  var angle = -math.pi / 2;
  for (final (i, s) in slices.indexed) {
    final sweep = s.value / total * 2 * math.pi;
    final a2 = angle + sweep;
    if (slices.length == 1) {
      out.writeln('<circle cx="${_n(cx)}" cy="${_n(cy)}" r="${_n(r)}" fill="${colorOf(i)}"/>');
    } else {
      final large = sweep > math.pi ? 1 : 0;
      String pt(double rad, double a) => '${_n(cx + rad * math.cos(a))} ${_n(cy + rad * math.sin(a))}';
      final d = inner > 0
          ? 'M${pt(r, angle)} A${_n(r)} ${_n(r)} 0 $large 1 ${pt(r, a2)} L${pt(inner, a2)} '
                'A${_n(inner)} ${_n(inner)} 0 $large 0 ${pt(inner, angle)} Z'
          : 'M${_n(cx)} ${_n(cy)} L${pt(r, angle)} A${_n(r)} ${_n(r)} 0 $large 1 ${pt(r, a2)} Z';
      out.writeln('<path d="$d" fill="${colorOf(i)}" stroke="#FFFFFF" stroke-width="2"/>');
    }
    // The share on the slice, when it fits.
    final share = s.value / total;
    if (share >= 0.06) {
      final mid = angle + sweep / 2;
      final lr = inner > 0 ? (r + inner) / 2 : r * 0.64;
      out.writeln(
        '<text x="${_n(cx + lr * math.cos(mid))}" y="${_n(cy + lr * math.sin(mid) + 4)}" font-size="12" '
        'font-weight="600" fill="#FFFFFF" text-anchor="middle">${_pct(share)}</text>',
      );
    }
    angle = a2;
  }
  // A total of shares means nothing; values in % are already shares.
  final shares = spec.unit == '%';
  if (inner > 0 && !shares) {
    out
      ..writeln(
        '<text x="${_n(cx)}" y="${_n(cy + 2)}" font-size="18" font-weight="600" fill="$_ink" text-anchor="middle">'
        '${_esc(spec.format(total))}</text>',
      )
      ..writeln(
        '<text x="${_n(cx)}" y="${_n(cy + 18)}" font-size="11" fill="$_muted" text-anchor="middle">Total</text>',
      );
  }
  // The legend: label, value and share.
  final lx = cx + r + 36;
  var ly = cy - slices.length * 11 + 8;
  for (final (i, s) in slices.indexed) {
    out
      ..writeln('<rect x="${_n(lx)}" y="${_n(ly - 9)}" width="10" height="10" rx="2" fill="${colorOf(i)}"/>')
      ..writeln(
        '<text x="${_n(lx + 16)}" y="${_n(ly)}" font-size="12" fill="$_ink">${_esc(_fit(s.label, 170, size: 12))}'
        '<tspan fill="$_muted">  ${shares ? '' : '${_esc(spec.format(s.value))} · '}${_pct(s.value / total)}</tspan></text>',
      );
    ly += 22;
  }
  return math.max(cy + r, ly) + 8;
}

String _pct(double share) {
  final p = share * 100;
  return '${p >= 10 || p == p.roundToDouble() ? p.round() : p.toStringAsFixed(1)}%';
}
