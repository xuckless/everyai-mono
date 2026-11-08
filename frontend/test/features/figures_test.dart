import 'dart:convert';

import 'package:every_ai/features/artifacts/domain/artifact.dart';
import 'package:every_ai/features/artifacts/domain/figures.dart';
import 'package:every_ai/features/artifacts/export/doc_model.dart';
import 'package:every_ai/features/chat/data/chat_transport.dart';
import 'package:every_ai/features/chat/domain/message.dart';
import 'package:flutter_test/flutter_test.dart';

Message _assistant(String id, List<ToolCallPart> calls) =>
    Message(id: id, conversationId: 'c', role: Role.assistant, parts: calls, createdAt: DateTime(2026));

ToolCallPart _call(String tool, Map<String, Object?> args, String id) =>
    ToolCallPart(toolName: tool, argumentsJson: jsonEncode(args), callId: id);

const _sun = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><circle id="sun" fill="#fc0"/></svg>';

void main() {
  test('a figure call with an id is a versioned artifact; edit_artifact revises it and the renderer key follows', () {
    final history = [
      _assistant('m1', [
        _call('render_svg', {'id': 'fig-sun', 'title': 'Sun', 'svg': _sun}, 'c1'),
        _call('render_svg', {'title': 'One-off', 'svg': _sun}, 'c2'),
      ]),
      _assistant('m2', [
        _call('edit_artifact', {
          'id': 'fig-sun',
          'edits': [
            {'old_text': '#fc0', 'new_text': '#f60'},
          ],
        }, 'c3'),
      ]),
    ];
    final artifacts = artifactsIn(history);
    expect(artifacts.map((a) => a.id), ['fig-sun']);
    final sun = artifacts.single;
    expect(sun.versions, hasLength(2));
    expect(sun.latest.kind, VisualKind.svg);
    expect(sun.latest.str('svg'), contains('#f60'));
    expect(sun.latest.str('content'), contains('#f60'));
    expect(figuresOf(artifacts)['fig-sun']?.source, contains('#f60'));
    // The model sees the figure's latest source after the turn, like any artifact.
    final notes = toolOutputsByMessage(history);
    expect(notes['m1'], contains('[render_svg fig-sun: an earlier version, superseded below]'));
    expect(notes['m2'], contains('<artifact id="fig-sun" kind="svg" title="Sun">'));
    expect(notes['m2'], contains('#f60'));
  });

  test('charts and diagrams with ids are figures too; a chart edit changes what is drawn', () {
    final history = [
      _assistant('m1', [
        _call('render_chart', {
          'id': 'fig-sales',
          'type': 'bar',
          'labels': ['Q1'],
          'series': [
            {
              'name': 'Sales',
              'values': [3],
            },
          ],
        }, 'c1'),
        _call('render_diagram', {'id': 'fig-flow', 'mermaid': 'graph TD; A-->B'}, 'c2'),
        _call('edit_artifact', {
          'id': 'fig-sales',
          'edits': [
            {'old_text': '"bar"', 'new_text': '"line"'},
          ],
        }, 'c3'),
      ]),
    ];
    final figures = figuresOf(artifactsIn(history));
    expect(figures.keys, unorderedEquals(['fig-sales', 'fig-flow']));
    expect(figures['fig-flow']!.kind, FigureKind.diagram);
    final sales = artifactsIn(history).firstWhere((a) => a.id == 'fig-sales').latest;
    expect(sales.args['type'], 'line');
  });

  test('figure references expand to the latest source with a caption; unknown ones stay visible', () {
    final figures = <String, Figure>{'fig-sun': (id: 'fig-sun', title: 'Sun', kind: FigureKind.svg, source: _sun)};
    const doc =
        '# Notes\n\n![The sun at noon](figure:fig-sun)\n\n![](figure:fig-gone)\n\n```\n![x](figure:fig-sun)\n```';
    final out = expandFigureRefs(doc, figures);
    expect(out, contains('```svg\n$_sun\n```\n*The sun at noon*'));
    expect(out, contains('*[Figure "fig-gone" is not in this chat]*'));
    // Inside a code fence a reference is text.
    expect(out, contains('```\n![x](figure:fig-sun)\n```'));
    expect(figureRefsIn(doc), ['fig-sun', 'fig-gone']);
    // Exports see the figure as an ordinary ```svg block.
    expect(parseDoc(out).whereType<FigureBlock>(), hasLength(1));
  });
}
