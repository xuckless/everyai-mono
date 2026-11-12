import 'dart:convert';

import 'package:every_ai/features/artifacts/domain/artifact.dart';
import 'package:every_ai/features/chat/data/chat_transport.dart';
import 'package:every_ai/features/artifacts/ui/renderers/svg_view.dart';
import 'package:every_ai/features/chat/domain/message.dart';
import 'package:flutter_test/flutter_test.dart';

Message _assistant(String id, List<ToolCallPart> calls) =>
    Message(id: id, conversationId: 'c', role: Role.assistant, parts: calls, createdAt: DateTime(2026));

ToolCallPart _call(String tool, Map<String, Object?> args, String id) =>
    ToolCallPart(toolName: tool, argumentsJson: jsonEncode(args), callId: id);

void main() {
  test('edit_artifact applies find-and-replace edits to the previous version', () {
    final artifacts = artifactsIn([
      _assistant('m1', [
        _call('create_artifact', {
          'id': 'doc',
          'title': 'Doc',
          'kind': 'markdown',
          'content': 'alpha\nbeta  \ngamma',
        }, 't1'),
      ]),
      _assistant('m2', [
        _call('edit_artifact', {
          'id': 'doc',
          'edits': [
            {'old_text': 'alpha', 'new_text': 'ALPHA'},
            {'old_text': 'beta\ngamma', 'new_text': 'BG'}, // trailing spaces differ
            {'old_text': 'nowhere', 'new_text': 'x'},
          ],
        }, 't2'),
        _call('edit_artifact', {'id': 'unknown', 'edits': []}, 't3'),
      ]),
    ]);
    expect(artifacts, hasLength(1));
    final latest = artifacts.single.latest;
    expect(latest.str('content'), 'ALPHA\nBG');
    expect(latest.kind, VisualKind.document);
    expect(latest.args['edit_missed'], ['nowhere']);
    expect(latest.callId, 't2');
  });

  test('history sends each artifact once, latest content in the message that last changed it', () {
    final history = [
      _assistant('m1', [
        _call('create_artifact', {'id': 'doc', 'title': 'Doc', 'kind': 'markdown', 'content': 'v1'}, 't1'),
        _call('make_quiz', {'title': 'Q', 'questions': []}, 't2'),
      ]),
      _assistant('m2', [
        _call('edit_artifact', {
          'id': 'doc',
          'edits': [
            {'old_text': 'v1', 'new_text': 'v2'},
          ],
        }, 't3'),
      ]),
    ];
    final out = toolOutputsByMessage(history);
    expect(out['m1'], contains('earlier version'));
    expect(out['m1'], contains('[Showed the user quiz: Q]'));
    expect(out['m1'], isNot(contains('v1')));
    expect(out['m2'], '<artifact id="doc" kind="markdown" title="Doc">\nv2\n</artifact>');
  });

  test('artifacts collect their versions across messages; updates keep kind and language', () {
    final artifacts = artifactsIn([
      _assistant('m1', [
        _call('create_artifact', {
          'id': 'app',
          'title': 'App',
          'kind': 'code',
          'language': 'dart',
          'content': 'v1',
        }, 't1'),
        _call('make_quiz', {'title': 'Q', 'questions': []}, 't2'),
      ]),
      _assistant('m2', [
        _call('update_artifact', {'id': 'app', 'content': 'v2'}, 't3'),
        _call('create_artifact', {'id': 'notes', 'title': 'Notes', 'kind': 'markdown', 'content': '# Hi'}, 't4'),
      ]),
    ]);
    expect(artifacts.map((a) => a.id), ['app', 'notes']);
    final app = artifacts.first;
    expect(app.versions.map((v) => v.str('content')), ['v1', 'v2']);
    expect(app.latest.kind, VisualKind.code);
    expect(app.latest.str('language'), 'dart');
    expect(app.title, 'App');
    expect(artifacts.last.latest.kind, VisualKind.document);
  });

  test('sanitizeSvg leaves nothing an HTML parser would bring to life', () {
    const open = '<svg xmlns="http://www.w3.org/2000/svg">';
    // XML keeps `--!>` inside the comment; HTML ends the comment there.
    final comment = sanitizeSvg('$open<!-- a --!><img src=x onerror=alert(1)> --><rect/></svg>');
    expect(comment, isNot(contains('onerror')));
    expect(comment, contains('<rect/>'));
    // Markup inside title/desc is HTML to a browser (`image` becomes `img`).
    const input =
        '$open<title>Chart<image src="https://evil.example/x?d=1" srcset="https://evil.example/y 1x"/></title>'
        '<desc><![CDATA[<img src=x onerror=alert(1)>]]></desc>'
        '<text><![CDATA[a < b]]></text><image src="https://evil.example/z" width="1"/></svg>';
    final title = sanitizeSvg(input);
    expect(title, isNot(contains('evil.example')));
    expect(title, isNot(contains('<img')));
    expect(title, isNot(contains('CDATA')));
    expect(title, contains('<title>Chart</title>'));
    expect(title, contains('<text>a &lt; b</text>'));
    // A second call (the cache) gives the same answer.
    expect(sanitizeSvg(input), title);
  });
}
