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
    test('a clean figure has no findings', () => expect(svgFindings(_good), isEmpty));

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

    test('text that runs off the canvas, sits outside it, is tiny or is faint', () {
      const svg =
          '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 100">'
          '<rect width="200" height="100" fill="#ffffff"/>'
          '<text x="150" y="50" font-size="20">A long label here</text>'
          '<text x="400" y="50">gone</text>'
          '<text x="10" y="90" font-size="2">tiny</text>'
          '<text x="10" y="30" fill="#eeeeee">faint</text>'
          '<rect id="far" x="300" y="0" width="10" height="10"/>'
          '<g transform="translate(500 0)"><rect x="0" y="0" width="5" height="5"/></g></svg>';
      final f = svgFindings(svg).join('\n');
      expect(f, contains('runs past the edge of the viewBox: "A long label here"'));
      expect(f, contains('never seen: <text>, <rect id="far">'));
      expect(f, contains('1 text element(s) are under 9 px'));
      expect(f, contains('too little contrast against the background: "faint"'));
    });
  });

  test('what the app does not draw, overlapping text, and lines through labels', () {
    const svg =
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 200">'
        '<defs><marker id="head"><path d="M0 0 L10 5 L0 10 Z"/></marker></defs>'
        '<line x1="20" y1="100" x2="380" y2="100" stroke="#000" marker-end="url(#head)"/>'
        '<text x="150" y="105" font-size="20">Evaporation</text>'
        '<text x="40" y="40" font-size="20">Condensation</text>'
        '<text x="60" y="44" font-size="20">Title here</text>'
        '<path d="M300 20 C 320 40, 340 60, 360 80"/></svg>';
    final f = svgFindings(svg).join('\n');
    expect(f, contains('<marker> arrowheads are not drawn'));
    expect(f, contains('Text overlaps other text: "Condensation" and "Title here"'));
    expect(f, contains('runs through text: "Evaporation"'));
    // A curve's shape isn't guessed at.
    const curve =
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 200">'
        '<text x="150" y="105" font-size="20">Label</text><path d="M100 100 C 200 100, 250 100, 300 100"/></svg>';
    expect(svgFindings(curve), isEmpty);
  });

  group('look', () {
    final drawn = <String>[];
    Looker looker() => Looker(
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

    test("a document's figures, references resolved, in order; a missing figure is reported", () async {
      drawn.clear();
      final history = [
        _assistant('m1', [
          _call('render_svg', {'id': 'fig-hi', 'svg': _good}, 'c1'),
          _call('create_artifact', {
            'id': 'report',
            'title': 'Report',
            'kind': 'markdown',
            'content': '# Report\n\nSome words here.\n\n![Hello](figure:fig-hi)\n\n![](figure:fig-nope)',
          }, 'c2'),
        ]),
      ];
      final answer = await looker().look('{"id":"report"}', history);
      expect(answer.pictures, hasLength(1));
      expect(drawn.single, contains('Hello'));
      expect(answer.text, contains('figure "fig-nope", which is not in this chat'));
      expect(answer.text, contains('1 headings'));
    });

    test('an unknown id lists the ids there are', () async {
      final history = [
        _assistant('m1', [
          _call('render_svg', {'id': 'fig-hi', 'svg': _good}, 'c1'),
        ]),
      ];
      final answer = await looker().look('{"id":"fig-x"}', history);
      expect(answer.isError, isTrue);
      expect(answer.text, contains('Ids here: fig-hi'));
    });
  });
}
