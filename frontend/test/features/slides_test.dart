import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:every_ai/features/artifacts/checks/look.dart';
import 'package:every_ai/features/artifacts/checks/slide_lint.dart';
import 'package:every_ai/features/artifacts/domain/artifact.dart';
import 'package:every_ai/features/artifacts/domain/slide_spec.dart';
import 'package:every_ai/features/artifacts/export/downloads.dart';
import 'package:every_ai/features/artifacts/ui/renderers/slide_canvas.dart';
import 'package:every_ai/features/chat/domain/message.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

Message _assistant(List<ToolCallPart> calls) =>
    Message(id: 'm', conversationId: 'c', role: Role.assistant, parts: calls, createdAt: DateTime(2026));

ToolCallPart _call(String tool, Map<String, Object?> args, String id) =>
    ToolCallPart(toolName: tool, argumentsJson: jsonEncode(args), callId: id);

const _svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 300 200"><circle cx="150" cy="100" r="60"/></svg>';

final _deckArgs = <String, Object?>{
  'id': 'deck-x',
  'title': 'Deck',
  'theme': 'navy',
  'slides': [
    {
      'title': 'Side',
      'layout': 'figure_right',
      'figure': 'fig-a',
      'caption': 'A circle',
      'bullets': ['One', 'Two **bold**'],
    },
    {
      'title': 'Free',
      'layout': 'free',
      'background': '#fdf6e3',
      'elements': [
        {
          'type': 'text',
          'x': 40,
          'y': 40,
          'w': 200,
          'h': 40,
          'text': 'A sentence far too long for this small box',
          'size': 32,
        },
        {'type': 'shape', 'shape': 'arrow', 'x': 300, 'y': 400, 'w': 200, 'h': -100, 'stroke': 'accent'},
        {
          'type': 'table',
          'x': 500,
          'y': 40,
          'w': 400,
          'h': 120,
          'rows': [
            ['Year', 'GW'],
            ['2025', '2400'],
          ],
        },
        {'type': 'figure', 'figure': 'fig-a', 'x': 500, 'y': 200, 'w': 400, 'h': 300},
        {'type': 'figure', 'figure': 'fig-gone', 'x': 980, 'y': 0, 'w': 100, 'h': 100},
        {'type': 'text', 'x': 60, 'y': 300, 'w': 300, 'h': 60, 'text': 'faint', 'color': '#fdf6e3', 'size': 10},
      ],
    },
  ],
};

void main() {
  final history = [
    _assistant([
      _call('render_svg', {'id': 'fig-a', 'svg': _svg}, 'c1'),
      _call('make_slides', _deckArgs, 'c2'),
    ]),
  ];

  test('presets and free slides lay out to elements; colours take hex and theme names', () {
    final deck = deckOf(artifactsIn(history).firstWhere((a) => a.id == 'deck-x').latest);
    expect(deck, hasLength(3));
    final side = deck[1].elements;
    expect(side.whereType<PictureElement>().single.ref, 'fig-a');
    final body = side.whereType<TextElement>().firstWhere((t) => t.paragraphs.any((p) => p.bullet));
    expect(body.paragraphs.last.runs.map((r) => (r.text, r.bold)), [('Two ', false), ('bold', true)]);
    final free = deck[2];
    expect(free.background, const Color(0xFFFDF6E3));
    expect(free.elements.whereType<ShapeElement>().single.stroke, DeckTheme.of('navy').accent);
    expect(free.elements.whereType<TableElement>().single.columns, 2);
  });

  test('a deck with an id is an artifact that edit_artifact revises', () {
    final edited = [
      ...history,
      _assistant([
        _call('edit_artifact', {
          'id': 'deck-x',
          'edits': [
            {'old_text': '"title":"Free"', 'new_text': '"title":"Designed"'},
          ],
        }, 'c3'),
      ]),
    ];
    final deck = deckOf(artifactsIn(edited).firstWhere((a) => a.id == 'deck-x').latest);
    expect(deck[2].title, 'Designed');
  });

  testWidgets('the lint measures text, and finds what is off the slide, missing or faint', (tester) async {
    final deck = deckOf(artifactsIn(history).firstWhere((a) => a.id == 'deck-x').latest);
    final f = slideFindings(deck[2], SlideArtBook({'fig-a': const PendingArt()})).join('\n');
    expect(f, contains('"A sentence far too long for …" needs about'));
    expect(f, contains('figure "fig-gone" is entirely off the slide'));
    expect(f, contains('text "faint" is 10 px'));
    expect(f, contains('text "faint" has too little contrast'));
    expect(f, contains('"A sentence far too long for …" has too little contrast'));
    expect(slideFindings(deck[1], SlideArtBook({'fig-a': const PendingArt()})), isEmpty);
  });

  testWidgets('look draws every slide offscreen and lists findings per slide', (tester) async {
    await tester.runAsync(() async {
      final answer = await const Looker().look('{"id":"deck-x"}', history);
      expect(answer.isError, isFalse);
      expect(answer.pictures, hasLength(3));
      // PNG signature.
      expect(answer.pictures.first.take(4), [0x89, 0x50, 0x4E, 0x47]);
      expect(answer.text, contains('slides 1-3 of 3'));
      expect(answer.text, contains('Slide 3: figure "fig-gone"'));
      final one = await const Looker().look('{"id":"deck-x","slide":2}', history);
      expect(one.pictures, hasLength(1));
      expect(one.text, contains('slide 2 of 3'));
      expect((await const Looker().look('{"id":"deck-x","slide":9}', history)).isError, isTrue);
    });
  });

  testWidgets('PowerPoint gets native text, shapes, a table and the figure as SVG with a PNG', (tester) async {
    await tester.runAsync(() async {
      final artifacts = artifactsIn(history);
      final bytes = await pptxOf(artifacts.firstWhere((a) => a.id == 'deck-x').latest, artifacts: artifacts);
      final zip = ZipDecoder().decodeBytes(bytes);
      String file(String name) => utf8.decode(zip.findFile(name)!.content as List<int>);
      final free = file('ppt/slides/slide3.xml');
      expect(free, contains('<a:tbl>'));
      expect(free, contains('<a:tailEnd type="triangle"'));
      expect(free, contains('flipV="1"'));
      expect(free, contains('<a:t>A sentence far too long for this small box</a:t>'));
      expect(free, contains('asvg:svgBlip'));
      expect(file('ppt/slides/_rels/slide3.xml.rels'), contains('../media/image'));
      expect(zip.files.map((f) => f.name), contains(matches(RegExp(r'ppt/media/image\d+\.svg'))));
      expect(file('[Content_Types].xml'), contains('Extension="svg"'));
      expect(file('ppt/slides/slide2.xml'), contains('<a:buChar'));
      if (Platform.environment['PPTX_OUT'] case final out?) File(out).writeAsBytesSync(bytes);
    });
  });
}
