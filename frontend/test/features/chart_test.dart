import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/artifacts/domain/chart_spec.dart';
import 'package:every_ai/features/artifacts/export/chart_svg.dart';
import 'package:every_ai/features/artifacts/export/doc_model.dart';
import 'package:every_ai/features/artifacts/export/svg_raster.dart';
import 'package:every_ai/features/artifacts/ui/renderers/chart_view.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

void main() {
  final grouped = ChartSpec.fromJson({
    'type': 'bar',
    'title': 'Revenue by region',
    'unit': r'$',
    'source': '[1], [3]',
    'caption': 'Asia grew fastest.',
    'categories': ['Europe', 'Asia', 'Americas'],
    'series': [
      {
        'name': '2024',
        'values': [120, 90, 150],
      },
      {
        'name': '2025',
        'values': [130, 140, '160'],
      },
    ],
  });

  test('the categories shorthand reads like points, and numbers in strings count', () {
    expect(grouped.categories, ['Europe', 'Asia', 'Americas']);
    expect(grouped.valueAt(grouped.series[1], 'Americas'), 160);
    expect(grouped.categorical, isTrue);
    expect(grouped.valueRange, (0, 160));
    expect(grouped.format(1200), r'$1200');
    expect(grouped.format(-5), r'-$5');
  });

  test('stacked bars size the axis by the stack', () {
    final stacked = ChartSpec.fromJson({...grouped.toJsonForTest(), 'stacked': true});
    expect(stacked.valueRange.$2, 310);
  });

  test('small slices fold into Other, and a single small one keeps its name', () {
    ChartSpec pie(List<num> values) => ChartSpec.fromJson({
      'type': 'donut',
      'series': [
        {
          'points': [
            for (final (i, v) in values.indexed) {'x': 'S$i', 'y': v},
          ],
        },
      ],
    });
    expect(pie([50, 30, 18, 1, 1]).slices.map((s) => s.label), ['S0', 'S1', 'S2', 'Other']);
    expect(pie([50, 30, 18, 2]).slices.map((s) => s.label), ['S0', 'S1', 'S2', 'S3']);
    expect(pie([50, 30, 18, 1, 1]).slices.last.value, 2);
  });

  test('the CSV has a row per x and a column per series, numeric x sorted', () {
    expect(grouped.csv, 'x,2024,2025\nEurope,120,130\nAsia,90,140\nAmericas,150,160\n');
    final line = ChartSpec.fromJson({
      'type': 'line',
      'x_label': 'Year',
      'series': [
        {
          'name': 'Users, total',
          'points': [
            {'x': 2025, 'y': 2.5},
            {'x': 2024, 'y': 1},
          ],
        },
      ],
    });
    expect(line.categorical, isFalse);
    expect(line.csv, 'Year,"Users, total"\n2024,1\n2025,2.5\n');
  });

  test('every kind draws as an SVG with a viewBox, and the chart rasterizes', () async {
    for (final type in ['bar', 'line', 'area', 'pie', 'donut', 'scatter']) {
      for (final horizontal in [false, true]) {
        final spec = ChartSpec.fromJson({
          ...grouped.toJsonForTest(),
          'type': type,
          'horizontal': horizontal,
          'reference_lines': [
            {'y': 125, 'label': 'Target'},
          ],
          'annotations': [
            {'x': 'Asia', 'label': 'New office'},
          ],
        });
        final svg = chartSvg(spec)!;
        expect(svg, startsWith('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 640 '));
        expect(svg, contains('Source: [1], [3]'));
        expect(svg, isNot(contains('NaN')), reason: '$type horizontal=$horizontal');
      }
    }
    expect(chartSvg(ChartSpec.fromJson({...grouped.toJsonForTest(), 'type': 'donut'}))!, contains('Total'));
    final figure = await rasterizeSvg(chartSvg(grouped)!);
    expect(figure, isNotNull);
  });

  test('a ```chart block in a document becomes a figure; bad JSON stays code', () {
    final doc = parseDoc(
      '# Report\n\n```chart\n{"type":"pie","series":[{"points":[{"x":"A","y":2},{"x":"B","y":1}]}]}\n```\n\n'
      '```chart\n{not json\n```\n',
    );
    expect(doc.whereType<FigureBlock>().single.svg, contains('<svg'));
    expect(doc.whereType<CodeBlock>().single.language, 'chart');
    expect(
      svgFiguresIn('```chart\n${'{"type":"bar","categories":["a"],"series":[{"values":[1]}]}'}\n```'),
      hasLength(1),
    );
  });

  testWidgets('every kind lays out, and Data shows the numbers', (tester) async {
    Widget host(ChartSpec spec) => m.MaterialApp(
      home: m.Material(
        child: EveryThemeScope(
          theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
          child: SingleChildScrollView(child: ChartView(spec: spec, showTitle: true)),
        ),
      ),
    );
    for (final type in ['bar', 'line', 'area', 'pie', 'donut', 'scatter']) {
      for (final extra in [
        <String, Object?>{},
        {'stacked': true},
        {'horizontal': true},
        {
          'stacked': true,
          'horizontal': true,
          'reference_lines': [
            {'y': 125, 'label': 'Target'},
          ],
        },
      ]) {
        await tester.pumpWidget(host(ChartSpec.fromJson({...grouped.toJsonForTest(), 'type': type, ...extra})));
        expect(tester.takeException(), isNull, reason: '$type $extra');
      }
    }
    await tester.pumpWidget(host(grouped));
    expect(find.text('Revenue by region'), findsOneWidget);
    expect(find.text('Source: [1], [3]'), findsOneWidget);
    await tester.tap(find.text('Data'));
    await tester.pump();
    expect(find.text('Copy CSV'), findsOneWidget);
    expect(find.text('Americas'), findsWidgets);
    expect(find.text('160'), findsOneWidget);
  });
}

extension on ChartSpec {
  /// The arguments [grouped] was made from, to vary one field at a time.
  Map<String, Object?> toJsonForTest() => {
    'type': type.name,
    'title': title,
    'unit': unit,
    'source': source,
    'caption': caption,
    'series': [
      for (final s in series)
        {
          'name': s.name,
          'points': [
            for (final p in s.points) {'x': p.x, 'y': p.y},
          ],
        },
    ],
  };
}
