import 'dart:convert';
import 'dart:ui';

import 'package:every_ai/features/artifacts/domain/svg_parts.dart';
import 'package:every_ai/features/artifacts/ui/look_row.dart';
import 'package:every_ai/features/chat/domain/message.dart';
import 'package:flutter_test/flutter_test.dart';

const _svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 100">
  <rect width="200" height="100" fill="#ffffff"/>
  <g id="sun" transform="translate(100,50)">
    <circle r="20" fill="#f5a623"/>
    <text x="0" y="40" text-anchor="middle" font-size="10">Sun</text>
  </g>
  <rect id="ground" x="0" y="80" width="200" height="20" fill="#3a7d44"/>
</svg>''';

void main() {
  group('svg parts', () {
    test('finds the viewBox and the part under a point by its id', () {
      expect(svgViewBox(_svg), const Rect.fromLTWH(0, 0, 200, 100));
      final parts = svgParts(_svg);
      expect(partAt(parts, const Offset(100, 50))?.id, 'sun');
      expect(partAt(parts, const Offset(10, 90))?.id, 'ground');
      expect(partAt(parts, const Offset(100, 88))?.label, '"Sun"');
    });

    test('hand edits swap colours everywhere and replace text, escaped', () {
      expect(svgColours(_svg), containsAll(['#ffffff', '#f5a623', '#3a7d44']));
      expect(svgTexts(_svg), ['Sun']);
      final out = editSvg(_svg, colours: {'#f5a623': '#ff0000'}, texts: {0: 'Sun & sky'});
      expect(out, contains('fill="#ff0000"'));
      expect(out, isNot(contains('#f5a623')));
      expect(out, contains('>Sun &amp; sky</text>'));
    });

    test('bad markup has no parts', () => expect(svgParts('<svg'), isEmpty));

    test('minified transforms (no separator between numbers) place parts instead of throwing', () {
      const svg =
          '<svg viewBox="0 0 100 100"><g transform="translate(-10-5)scale(2)"><rect id="box" x="10" y="10" width="10" height="10"/></g></svg>';
      final box = svgParts(svg).singleWhere((p) => p.id == 'box').box;
      expect(box, const Rect.fromLTWH(10, 15, 20, 20));
    });
  });

  group('look outcome', () {
    ToolCallPart call(String? result) =>
        ToolCallPart(toolName: 'look', argumentsJson: jsonEncode({'id': 'fig'}), callId: 'c1', resultJson: result);

    test('running, failed and done', () {
      expect(LookOutcome.of(call(null)), isA<LookRunning>());
      expect(LookOutcome.of(call(jsonEncode({'id': 'fig', 'error': 'No artifact'}))), isA<LookFailed>());
      final done = LookOutcome.of(
        call(
          jsonEncode({
            'id': 'fig',
            'findings': ['a', 'b'],
            'pictures': <String>[],
          }),
        ),
      );
      expect(done, isA<LookDone>().having((d) => d.findings.length, 'findings', 2));
      expect(done.id, 'fig');
    });
  });
}
