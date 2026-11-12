import 'dart:convert';
import 'dart:typed_data';

import 'package:every_ai/features/artifacts/checks/look.dart';
import 'package:every_ai/features/artifacts/checks/svg_lint.dart';
import 'package:every_ai/features/chat/domain/message.dart';
import 'package:flutter_test/flutter_test.dart';

Message _assistant(String id, List<ToolCallPart> calls) =>
    Message(id: id, conversationId: 'c', role: Role.assistant, parts: calls, createdAt: DateTime(2026));

ToolCallPart _call(String tool, Map<String, Object?> args, String id) =>
    ToolCallPart(toolName: tool, argumentsJson: jsonEncode(args), callId: id);

const _good =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 100">'
    '<rect width="200" height="100" fill="#ffffff"/><text x="100" y="60" font-size="20" text-anchor="middle" '
    'fill="#222222">Hello</text></svg>';

void main() {
  group('svg lint', () {
    test('finds what a picture alone would not explain', () {
      const bad =
          '<svg xmlns="http://www.w3.org/2000/svg">'
          '<circle id="a" cx="5" cy="5" r="2" fill="url(#missing)"/><circle id="a" r="1"/><script>x()</script></svg>';
      final f = svgFindings(bad).join('\n');
      expect(f, contains('no valid viewBox'));
      expect(f, contains('"a" is used 2 times'));
      expect(f, contains('#missing, which is not defined'));
      expect(f, contains('removes <script>'));
      expect(svgFindings('<svg><g></svg>').single, contains('not valid XML'));
    });
  });

  group('look', () {
    final drawn = <String>[];
    Looker looker() => Looker(
      capturePages: (markdown) async => [
        Uint8List.fromList([9]),
      ],
      rasterize: (svg) async {
        drawn.add(svg);
        return (png: Uint8List.fromList([1, 2, 3]), width: 10.0, height: 10.0);
      },
    );

    test('a figure made this turn comes back as a picture with the checks', () async {
      drawn.clear();
      final history = [
        _assistant('m1', [
          _call('render_svg', {'id': 'fig-hi', 'svg': _good.replaceFirst('font-size="20"', 'font-size="2"')}, 'c1'),
        ]),
      ];
      final answer = await looker().look('{"id":"fig-hi"}', history);
      expect(answer.isError, isFalse);
      expect(answer.pictures, hasLength(1));
      expect(answer.text, contains('"fig-hi", SVG figure'));
      expect(answer.text, contains('under 9 px'));
    });
  });
}
