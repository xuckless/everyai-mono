import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/artifacts/checks/tool_checks.dart';
import 'package:every_ai/features/artifacts/domain/artifact.dart';
import 'package:every_ai/features/artifacts/domain/drawing.dart';
import 'package:every_ai/features/artifacts/export/downloads.dart';
import 'package:every_ai/features/artifacts/ui/artifact_panel.dart';
import 'package:every_ai/features/artifacts/ui/renderers/drawing_page.dart';
import 'package:every_ai/features/artifacts/ui/renderers/sandbox.dart';
import 'package:every_ai/features/chat/chat_providers.dart';
import 'package:every_ai/features/chat/data/chat_transport.dart';
import 'package:every_ai/features/chat/domain/message.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _scene = '{"type":"excalidraw","elements":[{"type":"rectangle","id":"a","x":0,"y":0,"label":{"text":"Hi"}}]}';

Message _assistant(String id, List<MessagePart> parts) =>
    Message(id: id, conversationId: 'c', role: Role.assistant, parts: parts, createdAt: DateTime(2026));

ToolCallPart _call(String tool, Map<String, Object?> args, String id) =>
    ToolCallPart(toolName: tool, argumentsJson: jsonEncode(args), callId: id);

class _Transport implements ChatTransport {
  final turns = <StreamController<ChatEvent>>[];
  final requests = <ChatRequest>[];

  @override
  Stream<ChatEvent> send(ChatRequest request, {Future<void>? cancel}) {
    requests.add(request);
    final turn = StreamController<ChatEvent>();
    turns.add(turn);
    return turn.stream;
  }
}

class _Catalog extends CatalogController {
  @override
  ModelCatalog build() => builtInCatalog;
}

void main() {
  group('drawing artifacts', () {
    test('create_artifact kind drawing is a drawing that opens in the panel', () {
      final v = Visual.fromPart(
        _call('create_artifact', {'id': 'd', 'title': 'Flow', 'kind': 'drawing', 'content': _scene}, '1'),
      )!;
      expect(v.kind, VisualKind.drawing);
      expect(v.kind.opensInPanel, isTrue);
      expect(drawingElementCount(v.str('content')), 1);
    });

    test('a user update keeps the drawing kind and becomes the next version', () {
      final artifacts = artifactsIn([
        _assistant('m', [
          _call('create_artifact', {'id': 'd', 'title': 'Flow', 'kind': 'drawing', 'content': _scene}, '1'),
          _call('update_artifact', {'id': 'd', 'content': '[]', 'edited_by': 'user'}, 'user-2'),
        ]),
      ]);
      expect(artifacts.single.versions, hasLength(2));
      expect(artifacts.single.latest.kind, VisualKind.drawing);
      expect(artifacts.single.latest.str('content'), '[]');
      expect(artifacts.single.title, 'Flow');
    });

    test('the model sees the saved scene in the next turn', () {
      final history = [
        _assistant('m', [
          _call('create_artifact', {'id': 'd', 'title': 'Flow', 'kind': 'drawing', 'content': _scene}, '1'),
          _call('update_artifact', {'id': 'd', 'content': '{"elements":[]}', 'edited_by': 'user'}, 'user-2'),
        ]),
      ];
      final note = toolOutputsByMessage(history)['m']!;
      expect(
        note,
        contains(
          '<artifact id="d" kind="drawing" title="Flow" edited_by="user">\n'
          '{"type":"excalidraw","elements":[]}\n</artifact>',
        ),
      );
      expect(note, contains('an earlier version, superseded'));
    });

    test('downloads as an .excalidraw file', () {
      final v = Visual.fromPart(
        _call('create_artifact', {'id': 'd', 'title': 'My Flow', 'kind': 'drawing', 'content': _scene}, '1'),
      )!;
      final e = exportOf(v);
      expect((e.extension, e.name, e.text), ('excalidraw', 'my-flow', _scene));
    });
  });

  group('drawingProblems', () {
    test('accepts scenes, bare element lists and skeleton elements', () {
      expect(drawingProblems(_scene), isEmpty);
      expect(drawingProblems('[{"type":"text","x":1,"y":2,"text":"a"}]'), isEmpty);
    });

    test('names what to fix', () {
      expect(drawingProblems(''), [contains('empty')]);
      expect(drawingProblems('a box'), [contains('not Excalidraw scene JSON')]);
      expect(drawingProblems('{"elements":[]}'), [contains('no elements')]);
      expect(drawingProblems('[{"type":"blob"}]'), [contains('elements[0].type')]);
      expect(drawingProblems('[{"type":"rectangle","x":"1"}]'), [contains('numbers')]);
      expect(drawingProblems('[{"type":"text"}]'), [contains('without text')]);
    });

    test('the app check reports a bad drawing to the model', () async {
      final check = await const AppToolChecker().check(
        'create_artifact',
        jsonEncode({'id': 'd', 'title': 'D', 'kind': 'drawing', 'content': 'nope'}),
      );
      expect(check.isError, isTrue);
      expect(check.text, contains('Excalidraw'));
    });
  });

  test('the model reads a slim copy of a saved scene: no files, app state or volatile fields', () {
    final scene = jsonEncode({
      'type': 'excalidraw',
      'version': 2,
      'appState': {'viewBackgroundColor': '#fff', 'zoom': 1},
      'files': {
        'f1': {'dataURL': 'data:image/png;base64,${'A' * 5000}'},
      },
      'elements': [
        {
          'id': 'box',
          'type': 'rectangle',
          'x': 10,
          'y': 20,
          'width': 100,
          'height': 50,
          'angle': 0,
          'strokeColor': '#e03131',
          'backgroundColor': 'transparent',
          'seed': 123,
          'version': 7,
          'versionNonce': 99,
          'updated': 1730000000000,
          'boundElements': [
            {'id': 't', 'type': 'text'},
          ],
          'groupIds': <String>[],
          'isDeleted': false,
        },
        {'id': 'gone', 'type': 'ellipse', 'x': 0, 'y': 0, 'isDeleted': true},
      ],
    });
    final slim = drawingForPrompt(scene);
    expect(slim, isNot(contains('dataURL')));
    expect(slim, isNot(contains('appState')));
    expect(slim, isNot(contains('seed')));
    expect(slim, isNot(contains('gone')));
    final box = (drawingElements(slim)!.single as Map<String, Object?>);
    expect(box, {
      'id': 'box',
      'type': 'rectangle',
      'x': 10,
      'y': 20,
      'width': 100,
      'height': 50,
      'strokeColor': '#e03131',
    });

    final many = jsonEncode([
      for (var i = 0; i < 100; i++) {'id': 'e$i', 'type': 'text', 'x': i, 'y': 0, 'text': 'x' * 50},
    ]);
    final capped = jsonDecode(drawingForPrompt(many, maxChars: 1000)) as Map<String, Object?>;
    expect((capped['elements']! as List).length, lessThan(20));
    expect((capped['elements']! as List).length + (capped['omitted_elements']! as int), 100);
    expect(drawingForPrompt('not json'), 'not json');
  });

  group('drawingPage', () {
    test('loads pinned Excalidraw and React from jsDelivr', () {
      final page = drawingPage(scene: _scene, dark: false);
      expect(page, contains('const CDN = "https://cdn.jsdelivr.net/npm/"'));
      expect(page, contains('"@excalidraw/excalidraw@$excalidrawVersion/+esm"'));
      expect(page, contains('react@$excalidrawReactVersion/+esm'));
      expect(page, contains('react-dom@$excalidrawReactVersion/client/+esm'));
      expect(page, contains('everyai: "scene"'));
      for (final url in RegExp(r'https://[^"\s)]+').allMatches(page).map((m) => m[0]!)) {
        expect(cdnAllowlist.any(url.startsWith), isTrue, reason: url);
      }
    });

    test('scene data cannot close its script element and stays valid JSON', () {
      const text = '</script><script>alert(1)</script> <!-- note --> a\u2028b\u2029c';
      final page = drawingPage(
        scene: jsonEncode([
          {'type': 'text', 'text': text},
        ]),
        dark: true,
      );
      final data = RegExp(
        r'<script type="application/json" id="everyai-drawing">(.*?)</script>',
        dotAll: true,
      ).firstMatch(page)![1]!;
      expect(data, isNot(contains('<')));
      expect(data, isNot(contains('\u2028')));
      final decoded = jsonDecode(data) as Map<String, Object?>;
      expect(decoded['scene'], contains(text));
      // The page reads the data inside its try, so a bad scene shows an error.
      expect(page.indexOf('JSON.parse(document'), greaterThan(page.indexOf('try {\n  const data')));
      expect(decoded['dark'], isTrue);
      expect(decoded['mermaid'], isNull);
    });

    test('a diagram to convert loads mermaid-to-excalidraw', () {
      final page = drawingPage(mermaid: 'graph TD; A-->B', dark: false);
      expect(page, contains('@excalidraw/mermaid-to-excalidraw@$mermaidToExcalidrawVersion/+esm'));
      expect(page, contains('"mermaid":"graph TD; A-->B"'));
    });

    test('only the drawing host forwards scenes', () {
      final drawing = sandboxedHostPage('<p>x</p>', surface: WebSurface.drawing, interactive: true, token: 't');
      expect(drawing, contains('callHandler("$sceneHandler","t",d.scene)'));
      final page = sandboxedHostPage('<p>x</p>', surface: WebSurface.page, interactive: true, token: 't');
      expect(page, isNot(contains(sceneHandler)));
    });
  });

  test('make editable: an unsaved drawing holding the Mermaid source', () {
    final diagram = Visual.fromPart(
      _call('render_diagram', {'title': 'Login', 'mermaid': 'graph TD; A-->B'}, 'call7'),
    )!;
    final id = drawingIdForDiagram('call7');
    expect(id, 'call7-drawing');
    expect(drawingIdForDiagram('weird id/with:chars'), 'weird-id-with-chars-drawing');
    final d = drawingFromDiagram(diagram, id: id);
    expect(d.kind, VisualKind.drawing);
    expect((d.title, d.str('id'), d.str('mermaid'), d.str('content')), ('Login', id, 'graph TD; A-->B', ''));
  });

  group('saveUserArtifact', () {
    late AppDatabase db;
    late ProviderContainer container;
    late _Transport transport;
    const id = 'conv-d';

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      transport = _Transport();
      final prefs = await Preferences.load(db);
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(prefs),
          chatTransportProvider.overrideWithValue(transport),
          chatClientToolsProvider.overrideWithValue(const {}),
          appToolCheckerProvider.overrideWithValue(const AppToolChecker()),
          modelCatalogProvider.overrideWith(_Catalog.new),
        ],
      );
      container.listen(chatSessionProvider(id), (_, _) {});
    });

    tearDown(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      container.dispose();
      await db.close();
    });

    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

    test('joins the last answer, is stored, and waits while a turn runs', () async {
      final ctl = container.read(chatSessionProvider(id).notifier);
      await settle();
      await ctl.send('draw a flow');
      expect(await ctl.saveUserArtifact('update_artifact', {'id': 'd', 'content': '[]'}), isFalse);
      transport.turns.single
        ..add(
          UiToolCall(
            id: 'call1',
            name: 'create_artifact',
            argumentsJson: jsonEncode({'id': 'd', 'title': 'Flow', 'kind': 'drawing', 'content': _scene}),
          ),
        )
        ..add(const TurnDone());
      unawaited(transport.turns.single.close());
      await settle();

      expect(await ctl.saveUserArtifact('update_artifact', {'id': 'd', 'content': '{"elements":[]}'}), isTrue);
      final messages = container.read(chatSessionProvider(id)).messages;
      expect(messages.map((m) => m.role), [Role.user, Role.assistant]);
      final calls = messages.last.parts.whereType<ToolCallPart>().toList();
      expect(calls.map((c) => c.toolName), ['create_artifact', 'update_artifact']);
      expect(jsonDecode(calls.last.argumentsJson), {'id': 'd', 'content': '{"elements":[]}', 'edited_by': 'user'});

      final artifact = artifactsIn(messages).single;
      expect((artifact.versions.length, artifact.latest.kind), (2, VisualKind.drawing));

      final stored = await container.read(chatRepositoryProvider).messages(id);
      expect(stored.last.parts.whereType<ToolCallPart>().map((c) => c.toolName), [
        'create_artifact',
        'update_artifact',
      ]);
    });
  });
}
