import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/widgets.dart';

import '../../../../core/theme/every_theme.dart';
import '../../domain/artifact.dart';

/// `render_chart`: `{type: line|bar|pie|scatter|area, x_label, y_label,
/// series: [{name, points: [{x, y}]}]}`. String x values become categories.
class ChartView extends StatelessWidget {
  const ChartView({super.key, required this.visual, this.height = 280});

  final Visual visual;
  final double height;

  /// Brand violet and cyan lead; the rest stay distinct from each other.
  static const palette = [
    EveryPalette.violet400,
    EveryPalette.cyan500,
    Color(0xFFE8833A),
    Color(0xFF2FA866),
    Color(0xFFD9488B),
    Color(0xFFC9A227),
    Color(0xFF3B8FE5),
    Color(0xFF8C6D5A),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final series = <(String, List<(Object, double)>)>[
      for (final s in (visual.args['series'] as List<Object?>?) ?? const [])
        if (s case {'points': final List<Object?> points})
          (
            s['name'] as String? ?? '',
            [
              for (final p in points)
                if (p case {'x': final Object x, 'y': final num y}) (x, y.toDouble()),
            ],
          ),
    ];
    if (series.isEmpty || series.every((s) => s.$2.isEmpty)) {
      return Text('No data to chart.', style: TextStyle(color: theme.textMuted));
    }
    final type = visual.str('type');
    // Categories in first-seen order; numeric x values plot as numbers.
    final categorical = series.any((s) => s.$2.any((p) => p.$1 is String)) || type == 'bar';
    final categories = <String>{
      for (final s in series)
        for (final p in s.$2) '${p.$1}',
    }.toList();
    double xOf(Object x) => categorical ? categories.indexOf('$x').toDouble() : (x as num).toDouble();
    final label = theme.type.footnote.tint(theme.textMuted);

    Widget bottomTitle(double v, TitleMeta meta) {
      if (!categorical) {
        return SideTitleWidget(
          meta: meta,
          child: Text(meta.formattedValue, style: label),
        );
      }
      final i = v.round();
      if (i != v || i < 0 || i >= categories.length) return const SizedBox.shrink();
      return SideTitleWidget(
        meta: meta,
        child: Text(categories[i], style: label, overflow: TextOverflow.ellipsis),
      );
    }

    final titles = FlTitlesData(
      topTitles: const AxisTitles(),
      rightTitles: const AxisTitles(),
      leftTitles: AxisTitles(
        axisNameWidget: visual.str('y_label').isEmpty ? null : Text(visual.str('y_label'), style: label),
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: 40,
          getTitlesWidget: (v, meta) => SideTitleWidget(
            meta: meta,
            child: Text(meta.formattedValue, style: label),
          ),
        ),
      ),
      bottomTitles: AxisTitles(
        axisNameWidget: visual.str('x_label').isEmpty ? null : Text(visual.str('x_label'), style: label),
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: 28,
          interval: categorical ? 1 : null,
          getTitlesWidget: bottomTitle,
        ),
      ),
    );
    final grid = FlGridData(
      drawVerticalLine: false,
      getDrawingHorizontalLine: (_) => FlLine(color: theme.border, strokeWidth: 1),
    );
    final border = FlBorderData(show: false);

    final Widget chart = switch (type) {
      'pie' => PieChart(
        PieChartData(
          sectionsSpace: 2,
          centerSpaceRadius: height * 0.18,
          sections: [
            for (final (i, p) in series.first.$2.indexed)
              PieChartSectionData(
                value: p.$2,
                color: palette[i % palette.length],
                title: '${p.$1}',
                radius: height * 0.26,
                titleStyle: theme.type.footnote.semibold.tint(Color(0xFFFFFFFF)),
              ),
          ],
        ),
      ),
      'bar' => BarChart(
        BarChartData(
          titlesData: titles,
          gridData: grid,
          borderData: border,
          barGroups: [
            for (final (ci, c) in categories.indexed)
              BarChartGroupData(
                x: ci,
                barsSpace: 3,
                barRods: [
                  for (final (si, s) in series.indexed)
                    BarChartRodData(
                      toY: s.$2.where((p) => '${p.$1}' == c).firstOrNull?.$2 ?? 0,
                      color: palette[si % palette.length],
                      width: (60 / (series.length * categories.length).clamp(1, 60)).clamp(4, 22),
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                    ),
                ],
              ),
          ],
        ),
      ),
      'scatter' => ScatterChart(
        ScatterChartData(
          titlesData: titles,
          gridData: grid,
          borderData: border,
          scatterSpots: [
            for (final (si, s) in series.indexed)
              for (final p in s.$2)
                ScatterSpot(
                  xOf(p.$1),
                  p.$2,
                  dotPainter: FlDotCirclePainter(radius: 4, color: palette[si % palette.length]),
                ),
          ],
        ),
      ),
      _ => LineChart(
        LineChartData(
          titlesData: titles,
          gridData: grid,
          borderData: border,
          lineBarsData: [
            for (final (si, s) in series.indexed)
              LineChartBarData(
                spots: [for (final p in s.$2) FlSpot(xOf(p.$1), p.$2)],
                isCurved: true,
                preventCurveOverShooting: true,
                color: palette[si % palette.length],
                barWidth: 2.5,
                dotData: FlDotData(show: s.$2.length <= 24),
                belowBarData: BarAreaData(
                  show: type == 'area',
                  color: palette[si % palette.length].withValues(alpha: 0.18),
                ),
              ),
          ],
        ),
      ),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: height,
          child: Padding(padding: const EdgeInsets.only(top: 8, right: 12), child: chart),
        ),
        if (series.length > 1 || type == 'pie')
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Wrap(
              spacing: 14,
              runSpacing: 6,
              children: [
                for (final (i, name)
                    in (type == 'pie' ? series.first.$2.map((p) => '${p.$1}') : series.map((s) => s.$1)).indexed)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: palette[i % palette.length],
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(name, style: theme.type.caption.tint(theme.text)),
                    ],
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
