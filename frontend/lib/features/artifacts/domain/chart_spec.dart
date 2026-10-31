import 'dart:convert';
import 'dart:math' as math;

// The one chart format: `render_chart` arguments and ```chart blocks inside
// Markdown artifacts. The app draws it with fl_chart (chart_view.dart) and
// downloads draw it as SVG (export/chart_svg.dart), so both read it here.

/// Kinds of chart. Unknown types draw as lines.
enum ChartType { bar, line, area, pie, donut, scatter }

/// Series colors: brand violet and cyan lead; the rest stay distinct from each other.
const chartPalette = [0xFF9C85FC, 0xFF00B1CE, 0xFFE8833A, 0xFF2FA866, 0xFFD9488B, 0xFFC9A227, 0xFF3B8FE5, 0xFF8C6D5A];

/// The color of the "Other" slice.
const chartOtherColor = 0xFFA3A3AD;

final class ChartPoint {
  const ChartPoint(this.x, this.y);

  /// A category (String) or a number.
  final Object x;
  final double y;
}

final class ChartSeries {
  const ChartSeries(this.name, this.points);
  final String name;
  final List<ChartPoint> points;
}

/// A marked point: a dashed line at [x] with [label] (the event, the peak).
final class ChartAnnotation {
  const ChartAnnotation(this.x, this.label);
  final Object x;
  final String label;
}

/// A dashed line across the chart at value [y] (a target, an average).
final class ChartReferenceLine {
  const ChartReferenceLine(this.y, this.label);
  final double y;
  final String label;
}

final class ChartSpec {
  const ChartSpec({
    required this.type,
    required this.series,
    this.title = '',
    this.caption = '',
    this.source = '',
    this.unit = '',
    this.xLabel = '',
    this.yLabel = '',
    this.stacked = false,
    this.horizontal = false,
    this.annotations = const [],
    this.referenceLines = const [],
    this.otherThreshold = 0.03,
  });

  final ChartType type;
  final List<ChartSeries> series;
  final String title;

  /// One or two sentences under the chart: what it shows.
  final String caption;

  /// Where the numbers come from: citation numbers ("[2], [5]") or a name.
  final String source;

  /// The values' unit: "%", "$", "ms", "people".
  final String unit;
  final String xLabel;
  final String yLabel;

  /// Bars: stack the series instead of grouping them.
  final bool stacked;

  /// Bars: categories down the side, bars running right (long labels).
  final bool horizontal;
  final List<ChartAnnotation> annotations;
  final List<ChartReferenceLine> referenceLines;

  /// Pie and donut: slices under this share of the total fold into "Other".
  final double otherThreshold;

  bool get isRound => type == ChartType.pie || type == ChartType.donut;

  /// Whether nothing would be drawn.
  bool get isEmpty => series.every((s) => s.points.isEmpty);

  /// Whether x values are categories (any string x, and always for bars and slices).
  bool get categorical => type == ChartType.bar || isRound || series.any((s) => s.points.any((p) => p.x is String));

  /// The categories in first-seen order.
  List<String> get categories => {
    for (final s in series)
      for (final p in s.points) xText(p.x),
  }.toList();

  /// [series]' value in [category], null when it has none.
  double? valueAt(ChartSeries series, String category) {
    for (final p in series.points) {
      if (xText(p.x) == category) return p.y;
    }
    return null;
  }

  /// Pie and donut slices from the first series: biggest first, the small ones folded into "Other".
  List<({String label, double value, bool other})> get slices {
    if (series.isEmpty) return const [];
    final points = [
      for (final p in series.first.points)
        if (p.y > 0) p,
    ]..sort((a, b) => b.y.compareTo(a.y));
    final total = points.fold(0.0, (t, p) => t + p.y);
    if (total <= 0) return const [];
    final kept = <({String label, double value, bool other})>[];
    var other = 0.0;
    var folded = 0;
    for (final p in points) {
      // At most 7 named slices, so colors stay distinct.
      if (p.y / total < otherThreshold || kept.length >= 7) {
        other += p.y;
        folded++;
      } else {
        kept.add((label: xText(p.x), value: p.y, other: false));
      }
    }
    // One small slice reads better under its own name.
    if (folded == 1) {
      final last = points.firstWhere((p) => !kept.any((k) => k.label == xText(p.x)));
      kept.add((label: xText(last.x), value: last.y, other: false));
    } else if (folded > 1) {
      kept.add((label: 'Other', value: other, other: true));
    }
    return kept;
  }

  /// The smallest and largest value the value axis must show (stacks summed; 0 for bars and areas).
  (double, double) get valueRange {
    var lo = double.infinity, hi = double.negativeInfinity;
    void see(double v) {
      lo = math.min(lo, v);
      hi = math.max(hi, v);
    }

    if (type == ChartType.bar && stacked) {
      for (final c in categories) {
        var up = 0.0, down = 0.0;
        for (final s in series) {
          final v = valueAt(s, c) ?? 0;
          if (v >= 0) {
            up += v;
          } else {
            down += v;
          }
        }
        see(up);
        see(down);
      }
    } else {
      for (final s in series) {
        for (final p in s.points) {
          see(p.y);
        }
      }
    }
    for (final r in referenceLines) {
      see(r.y);
    }
    if (lo == double.infinity) return (0, 1);
    if (type == ChartType.bar || type == ChartType.area) {
      lo = math.min(lo, 0);
      hi = math.max(hi, 0);
    }
    if (lo == hi) hi = lo + 1;
    return (lo, hi);
  }

  /// [v] with the unit: "$1,200", "42%", "3.5 ms".
  String format(double v) {
    final n = formatNumber(v);
    if (unit.isEmpty) return n;
    if (const {r'$', '€', '£', '¥'}.contains(unit)) return v < 0 ? '-$unit${formatNumber(-v)}' : '$unit$n';
    if (unit == '%') return '$n%';
    return '$n $unit';
  }

  /// The numbers as CSV: one row per x, one column per series.
  String get csv {
    String cell(String s) => s.contains(RegExp('[",\n]')) ? '"${s.replaceAll('"', '""')}"' : s;
    final xs = categorical
        ? categories
        : ({
            for (final s in series)
              for (final p in s.points) p.x as num,
          }.toList()..sort()).map(xText).toList();
    final out = StringBuffer()
      ..writeln(
        [cell(xLabel.isEmpty ? 'x' : xLabel), for (var i = 0; i < series.length; i++) cell(seriesName(i))].join(','),
      );
    for (final x in xs) {
      out.writeln([cell(x), for (final s in series) _cell(valueAt(s, x))].join(','));
    }
    return out.toString();
  }

  /// A series' name, or "Series n" when it has none.
  String seriesName(int i) =>
      series[i].name.isNotEmpty ? series[i].name : (series.length == 1 ? 'Value' : 'Series ${i + 1}');

  /// Reads a spec from `render_chart` arguments or a ```chart block's JSON.
  /// Besides `series: [{name, points: [{x, y}]}]` it takes the common
  /// shorthand `categories: [...]` with `series: [{name, values: [...]}]`.
  static ChartSpec fromJson(Map<String, Object?> j) {
    final cats = _list(j['categories'] ?? j['labels'] ?? j['x']);
    final series = <ChartSeries>[];
    for (final s in _list(j['series'] ?? j['datasets'])) {
      if (s is! Map) continue;
      final name = '${s['name'] ?? s['label'] ?? ''}';
      final points = <ChartPoint>[];
      final raw = s['points'];
      if (raw is List) {
        for (final p in raw) {
          if (p is Map) {
            final y = _num(p['y'] ?? p['value']);
            final x = p['x'] ?? p['label'] ?? p['name'];
            if (y != null && x != null) points.add(ChartPoint(x is num ? x : '$x', y));
          } else if (p is List && p.length >= 2) {
            final y = _num(p[1]);
            if (y != null && p[0] != null) points.add(ChartPoint(p[0] is num ? p[0] as num : '${p[0]}', y));
          }
        }
      } else {
        final values = _list(s['values'] ?? s['data']);
        for (final (i, v) in values.indexed) {
          final y = _num(v);
          if (y != null) points.add(ChartPoint(i < cats.length ? '${cats[i]}' : '${i + 1}', y));
        }
      }
      series.add(ChartSeries(name, points));
    }
    return ChartSpec(
      type: ChartType.values.where((t) => t.name == j['type']).firstOrNull ?? ChartType.line,
      series: series,
      title: _str(j['title']),
      caption: _str(j['caption']),
      source: _str(j['source']),
      unit: _str(j['unit']),
      xLabel: _str(j['x_label']),
      yLabel: _str(j['y_label']),
      stacked: j['stacked'] == true,
      horizontal: j['horizontal'] == true,
      annotations: [
        for (final a in _list(j['annotations']))
          if (a is Map && a['x'] != null)
            ChartAnnotation(a['x'] is num ? a['x'] as num : '${a['x']}', _str(a['label'])),
      ],
      referenceLines: [
        for (final r in _list(j['reference_lines']))
          if (r is Map && _num(r['y']) != null) ChartReferenceLine(_num(r['y'])!, _str(r['label'])),
      ],
      otherThreshold: (_num(j['other_threshold']) ?? 0.03).clamp(0, 0.5),
    );
  }

  /// A ```chart block's text as a spec; null when it isn't a JSON object with data.
  static ChartSpec? tryParse(String text) {
    try {
      final j = jsonDecode(text);
      if (j is! Map<String, Object?>) return null;
      final spec = fromJson(j);
      return spec.isEmpty ? null : spec;
    } on FormatException {
      return null;
    }
  }
}

/// A category or numeric x as text ("2024", not "2024.0").
String xText(Object x) => x is num ? formatNumberPlain(x.toDouble()) : '$x';

/// [v] for axes and labels: thousands separated, at most 2 decimals, big numbers shortened (1.2M).
String formatNumber(double v) {
  final a = v.abs();
  if (a >= 1e9) return '${_trim((v / 1e9).toStringAsFixed(1))}B';
  if (a >= 1e6) return '${_trim((v / 1e6).toStringAsFixed(1))}M';
  if (a >= 1e4) return _thousands(v.round());
  return _trim(v.toStringAsFixed(a >= 100 ? 0 : 2));
}

/// [v] in full, for tables and CSV.
String formatNumberPlain(double v) => v == v.roundToDouble() && v.abs() < 1e15 ? '${v.toInt()}' : _trim('$v');

String _thousands(int n) {
  final s = n.abs().toString();
  final out = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}

String _trim(String s) => s.contains('.') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;

List<Object?> _list(Object? v) => v is List ? v : const [];

String _str(Object? v) => v is String ? v.trim() : '';

double? _num(Object? v) => switch (v) {
  final num n when n.isFinite => n.toDouble(),
  final String s => double.tryParse(s.replaceAll(RegExp(r'[,\s%$€£]'), '')),
  _ => null,
};

String _cell(double? v) => v == null ? '' : formatNumberPlain(v);
