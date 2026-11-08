import 'dart:convert';
import 'dart:typed_data';

import 'package:every_ai/features/artifacts/checks/capture.dart';
import 'package:every_ai/features/artifacts/checks/look.dart';
import 'package:every_ai/features/artifacts/checks/svg_lint.dart';
import 'package:every_ai/features/artifacts/domain/artifact.dart';
import 'package:every_ai/features/artifacts/domain/chart_spec.dart';
import 'package:every_ai/features/artifacts/domain/slide_pictures.dart';
import 'package:every_ai/features/artifacts/domain/slide_spec.dart';
import 'package:every_ai/features/artifacts/export/chart_svg.dart';
import 'package:every_ai/features/artifacts/ui/renderers/slide_canvas.dart';
import 'package:every_ai/features/chat/domain/message.dart';
import 'package:everyai_markdown/everyai_markdown.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

// The four gaps left after the agent trials: rotated groups in the SVG checks, page cuts through a line, wide
// tables cut off in page pictures, and charts on dark slides drawn as a white card.

ToolCallPart _call(String tool, Map<String, Object?> args, String id) =>
    ToolCallPart(toolName: tool, argumentsJson: jsonEncode(args), callId: id);

String _svg(String body) => '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 300">$body</svg>';

final _chart = <String, Object?>{
  'id': 'chart-a',
  'type': 'bar',
  'title': 'Sales',
  'categories': ['A', 'B'],
  'series': [
    {
      'name': 'Units',
      'values': [3, 5],
    },
  ],
};

void main() {
  group('svg checks under rotation', () {
    test('a line through a rotated label is found, and one beside it is not', () {
      const label = '<g transform="rotate(-90 100 150)"><text x="100" y="150" font-size="20">Pressure</text></g>';
      // The label runs upward from (100, 150), so x = 100 crosses it and y = 100 at x 40..60 passes beside it.
      final through = svgFindings(_svg('<line x1="90" y1="110" x2="110" y2="110" stroke="#000"/>$label'));
      expect(through.join('\n'), contains('runs through text: "Pressure"'));
      final beside = svgFindings(_svg('<line x1="140" y1="110" x2="200" y2="110" stroke="#000"/>$label'));
      expect(beside.join('\n'), isNot(contains('runs through text')));
    });

    test('slanted axis labels side by side do not overlap, though their boxes do', () {
      final labels = [
        for (var i = 0; i < 4; i++)
          '<text x="${60 + i * 40}" y="250" font-size="14" text-anchor="end" '
              'transform="rotate(-45 ${60 + i * 40} 250)">Category $i</text>',
      ].join();
      expect(svgFindings(_svg(labels)).join('\n'), isNot(contains('overlaps')));
      // Turned the same way at the same spot, two labels do overlap.
      const twin =
          '<g transform="rotate(30 200 150)"><text x="200" y="150" font-size="16">Twin one</text>'
          '<text x="204" y="152" font-size="16">Twin two</text></g>';
      expect(svgFindings(_svg(twin)).join('\n'), contains('Text overlaps other text'));
    });

    test('rotated text past the edge, scaled-down text and a matrix are placed', () {
      final off = svgFindings(
        _svg('<text x="380" y="200" font-size="18" transform="rotate(90 380 200)">Long side label</text>'),
      );
      expect(off.join('\n'), contains('runs past the edge'));
      final tiny = svgFindings(
        _svg('<g transform="matrix(0.2 0 0 0.2 10 10)"><text x="0" y="40" font-size="20">Tiny</text></g>'),
      );
      expect(tiny.join('\n'), contains('under 9 px'));
    });

    test('a rotated filled shape drawn over a line hides it under its label', () {
      final hidden = svgFindings(
        _svg(
          '<line x1="0" y1="150" x2="400" y2="150" stroke="#000"/>'
          '<g transform="rotate(10 200 150)"><rect x="140" y="130" width="120" height="40" fill="#eeeeee"/>'
          '<text x="200" y="157" font-size="16" text-anchor="middle">Node</text></g>',
        ),
      );
      expect(hidden.join('\n'), isNot(contains('runs through text')));
    });
  });

  group('page cuts', () {
    // A white picture 100 wide with "lines of text" (striped rows) 18 tall and 8-pixel gaps between them.
    Uint8List page(int height) {
      final rgba = Uint8List(100 * height * 4)..fillRange(0, 100 * height * 4, 255);
      for (var y = 0; y < height; y++) {
        if (y % 26 >= 18) continue;
        for (var x = 0; x < 100; x += 2) {
          rgba.fillRange((y * 100 + x) * 4, (y * 100 + x) * 4 + 3, 0);
        }
      }
      return rgba;
    }

    test('a page ends in the gap between two lines, not through one', () {
      final breaks = pageBreaks(page(1000), 100, 1000, pageHeight: 300);
      expect(breaks, isNotEmpty);
      for (final b in breaks) {
        expect((b - 1) % 26, greaterThanOrEqualTo(18), reason: 'row ${b - 1} is a gap');
      }
      expect(breaks.first, lessThanOrEqualTo(300));
    });

    test('with no gap (a picture) it cuts at the page height', () {
      final rgba = Uint8List(100 * 700 * 4);
      for (var i = 0; i < rgba.length; i += 8) {
        rgba.fillRange(i, i + 3, 255);
      }
      expect(pageBreaks(rgba, 100, 700, pageHeight: 300), [300, 600]);
    });
  });

  testWidgets('a wide table in a still layout is shrunk to fit instead of cut off', (tester) async {
    final row = List.filled(9, 'A fairly long cell').join(' | ');
    final table = '| $row |\n|${List.filled(9, '---').join('|')}|\n| $row |';
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            child: StillLayout(
              child: MarkdownView(data: table, style: MarkdownStyle.fallback(Brightness.light)),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(SingleChildScrollView), findsNothing);
    final fitted = tester.getSize(find.byType(FittedBox).first);
    expect(fitted.width, lessThanOrEqualTo(400));
  });

  group('charts on slides', () {
    test('on a dark colour a chart has no white card and light text', () {
      final spec = ChartSpec.fromJson(_chart);
      expect(chartSvg(spec), contains('fill="#FFFFFF"/>'));
      final dark = chartSvg(spec, on: 0xFF0F2547)!;
      expect(dark, isNot(contains('<rect width="100%" height="100%"')));
      expect(dark, contains('fill="#F2F2F7"'));
      final light = chartSvg(spec, on: 0xFFFDF6E3)!;
      expect(light, isNot(contains('<rect width="100%" height="100%"')));
      expect(light, contains('fill="#1C1C1E"'));
    });

    testWidgets('a deck draws its chart for the colour behind it', (tester) async {
      final history = [
        Message(
          id: 'm',
          conversationId: 'c',
          role: Role.assistant,
          createdAt: DateTime(2026),
          parts: [
            _call('render_chart', _chart, 'c1'),
            _call('make_slides', {
              'id': 'deck-d',
              'title': 'Dark',
              'theme': 'navy',
              'slides': [
                {'title': 'Chart', 'layout': 'figure', 'figure': 'chart-a'},
                {
                  'title': 'On a card',
                  'layout': 'free',
                  'elements': [
                    {'type': 'shape', 'shape': 'rect', 'x': 40, 'y': 100, 'w': 880, 'h': 400, 'fill': '#ffffff'},
                    {'type': 'figure', 'figure': 'chart-a', 'x': 60, 'y': 120, 'w': 840, 'h': 360},
                  ],
                },
              ],
            }, 'c2'),
          ],
        ),
      ];
      final artifacts = artifactsIn(history);
      final deck = deckOf(artifacts.firstWhere((a) => a.id == 'deck-d').latest);
      final uses = pictureUsesOf(deck);
      expect(uses.map((u) => u.on.toARGB32()).toSet(), {0xFF0F2547, 0xFFFFFFFF});
      expect(slideSourcesOf(artifacts)['chart-a'], isA<ChartSource>());
      await tester.runAsync(() async {
        final art = await drawSlideArt(uses, slideSourcesOf(artifacts));
        try {
          final onNavy = art.of('chart-a', on: const Color(0xFF0F2547));
          final onWhite = art.of('chart-a', on: const Color(0xFFFFFFFF));
          expect(onNavy, isA<VectorArt>());
          expect(onWhite, isA<VectorArt>());
          expect(identical(onNavy, onWhite), isFalse);
        } finally {
          art.dispose();
        }
        final answer = await const Looker().look('{"id":"deck-d"}', history);
        expect(answer.isError, isFalse);
        expect(answer.text, isNot(contains("can't be shown")));
      });
    });
  });
}
