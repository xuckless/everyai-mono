import 'dart:async';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/artifacts/artifact_providers.dart';
import 'package:every_ai/features/artifacts/checks/tool_checks.dart';
import 'package:every_ai/features/artifacts/data/artifact_library.dart';
import 'package:every_ai/features/artifacts/domain/artifact.dart';
import 'package:every_ai/features/artifacts/export/pptx_writer.dart';
import 'package:every_ai/features/artifacts/ui/panel_split.dart';
import 'package:every_ai/features/chat/chat_providers.dart';
import 'package:every_ai/features/chat/data/chat_transport.dart';
import 'package:every_ai/features/chat/domain/message.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Message _assistant(String id, List<MessagePart> parts, {String conversationId = 'c'}) =>
    Message(id: id, conversationId: conversationId, role: Role.assistant, parts: parts, createdAt: DateTime(2026));

ToolCallPart _call(String tool, Map<String, Object?> args, String id) =>
    ToolCallPart(toolName: tool, argumentsJson: jsonEncode(args), callId: id);

class _Transport implements ChatTransport {
  final turns = <StreamController<ChatEvent>>[];

  @override
  Stream<ChatEvent> send(ChatRequest request, {Future<void>? cancel}) {
    final turn = StreamController<ChatEvent>();
    turns.add(turn);
    return turn.stream;
  }
}

class _Catalog extends CatalogController {
  @override
  ModelCatalog build() => builtInCatalog;
}

String _file(Archive zip, String name) => utf8.decode(zip.findFile(name)!.content as List<int>);

void main() {
  group('user-edited versions', () {
    final history = [
      _assistant('m1', [
        _call('create_artifact', {'id': 'doc', 'title': 'Notes', 'kind': 'markdown', 'content': '# A'}, 't1'),
        _call('update_artifact', {'id': 'doc', 'content': '# B', 'edited_by': 'user'}, 'user-1'),
      ]),
    ];

    test('a hand edit is the next version and is marked for the model', () {
      final a = artifactsIn(history).single;
      expect(a.versions.map((v) => v.editedByUser), [false, true]);
      expect(a.latest.str('content'), '# B');
      final out = toolOutputsByMessage(history);
      expect(
        out['m1'],
        contains('<artifact id="doc" kind="markdown" title="Notes" edited_by="user">\n# B\n</artifact>'),
      );
    });

    test('a later model update or edit is not marked as the user\'s', () {
      final a = artifactsIn([
        ...history,
        _assistant('m2', [
          _call('edit_artifact', {
            'id': 'doc',
            'edits': [
              {'old_text': 'B', 'new_text': 'C'},
            ],
          }, 't2'),
          _call('update_artifact', {'id': 'doc', 'content': '# D'}, 't3'),
        ]),
      ]).single;
      expect(a.versions.map((v) => v.editedByUser), [false, true, false, false]);
      expect(a.versions[2].str('content'), '# C');
    });

    test('text kinds are editable; drawings, images and non-artifacts are not', () {
      Visual v(String kind) => Visual.fromPart(_call('create_artifact', {'id': 'x', 'kind': kind}, kind))!;
      expect(['markdown', 'code', 'html', 'svg', 'mermaid'].map((k) => editableAsText(v(k))), everyElement(isTrue));
      expect(editableAsText(v('drawing')), isFalse);
      expect(editableAsText(Visual.fromPart(_call('make_quiz', {'questions': []}, 'q'))!), isFalse);
      final image = imageVisual(ImagePart(bytes: utf8.encode('<svg/>'), mimeType: 'image/svg+xml', imageId: 'img_1'));
      expect(editableAsText(image), isFalse);
    });
  });

  group('ArtifactEditor', () {
    late AppDatabase db;
    late ProviderContainer container;
    late _Transport transport;
    const id = 'conv-e';

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      transport = _Transport();
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(await Preferences.load(db)),
          chatTransportProvider.overrideWithValue(transport),
          chatClientToolsProvider.overrideWithValue(const {}),
          appToolCheckerProvider.overrideWithValue(const AppToolChecker()),
          modelCatalogProvider.overrideWith(_Catalog.new),
        ],
      );
      container.listen(chatSessionProvider(id), (_, _) {});
      container.listen(artifactEditProvider(id), (_, _) {});
    });

    tearDown(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      container.dispose();
      await db.close();
    });

    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

    test('saves the text as a new user version; unchanged text saves nothing', () async {
      final chat = container.read(chatSessionProvider(id).notifier);
      await settle();
      await chat.send('write notes');
      transport.turns.single
        ..add(
          const UiToolCall(
            id: 'call1',
            name: 'create_artifact',
            argumentsJson: '{"id":"n","title":"Notes","kind":"markdown","content":"# Old"}',
          ),
        )
        ..add(const TurnDone());
      unawaited(transport.turns.single.close());
      await settle();

      final editor = container.read(artifactEditProvider(id).notifier);
      final base = artifactsIn(container.read(chatSessionProvider(id)).messages).single.latest;
      editor.start('n', base);
      expect(container.read(artifactEditProvider(id))!.changed, isFalse);
      expect(await editor.save(), isTrue);
      expect(artifactsIn(container.read(chatSessionProvider(id)).messages).single.versions, hasLength(1));

      editor
        ..start('n', base)
        ..update('# New');
      expect(container.read(artifactEditProvider(id))!.changed, isTrue);
      expect(await editor.save(), isTrue);
      expect(container.read(artifactEditProvider(id)), isNull);
      final artifact = artifactsIn(container.read(chatSessionProvider(id)).messages).single;
      expect(artifact.versions, hasLength(2));
      expect(
        (artifact.latest.str('content'), artifact.latest.editedByUser, artifact.latest.kind),
        ('# New', true, VisualKind.document),
      );
      final stored = artifactsIn(await container.read(chatRepositoryProvider).messages(id)).single;
      expect(stored.latest.str('content'), '# New');
    });
  });

  group('persisted panel state', () {
    test('quiz answers and flashcard progress survive a new container', () {
      final prefs = Preferences.inMemory();
      ProviderContainer make() => ProviderContainer(overrides: [preferencesProvider.overrideWithValue(prefs)]);

      final first = make();
      first.read(quizAnswersProvider('q1').notifier)
        ..answer(0, 1)
        ..answer(1, 5)
        ..answer(0, 2); // first answer counts
      first.read(flashcardProgressProvider('f1').notifier)
        ..mark(known: true, count: 3)
        ..mark(known: false, count: 3)
        ..go(-1, 3);
      first.dispose();

      final second = make();
      expect(second.read(quizAnswersProvider('q1')), {0: 1, 1: 5});
      final p = second.read(flashcardProgressProvider('f1'));
      expect(p.index, 1);
      expect(p.known, {0});
      expect(p.learning, {1});
      second.read(quizAnswersProvider('q1').notifier).reset();
      expect(prefs['artifacts.quiz.q1'], isNull);
      second.dispose();
    });

    test('a bad saved value starts fresh', () {
      final prefs = Preferences.inMemory({'artifacts.quiz.q': 'nope', 'artifacts.cards.f': '{"index":"x"}'});
      final c = ProviderContainer(overrides: [preferencesProvider.overrideWithValue(prefs)]);
      expect(c.read(quizAnswersProvider('q')), isEmpty);
      expect(c.read(flashcardProgressProvider('f')).index, 0);
      c.dispose();
    });

    test('panel width is clamped and remembered', () {
      expect(PanelSplit.widthFor(null, 1400), 728);
      expect(PanelSplit.widthFor(100, 1400), PanelSplit.minSide);
      expect(PanelSplit.widthFor(1300, 1400), 1040);
      expect(PanelSplit.widthFor(500, 700), PanelSplit.minSide);

      final prefs = Preferences.inMemory();
      final c = ProviderContainer(overrides: [preferencesProvider.overrideWithValue(prefs)]);
      c.read(artifactPanelWidthProvider.notifier).set(512.4, persist: false);
      expect(prefs['artifacts.panel_width'], isNull);
      c.read(artifactPanelWidthProvider.notifier).set(512.4);
      expect(prefs['artifacts.panel_width'], '512');
      c.dispose();
      final again = ProviderContainer(overrides: [preferencesProvider.overrideWithValue(prefs)]);
      expect(again.read(artifactPanelWidthProvider), 512);
      again.dispose();
    });

    testWidgets('dragging the divider resizes the panel', (tester) async {
      final prefs = Preferences.inMemory();
      await tester.binding.setSurfaceSize(const Size(1400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [preferencesProvider.overrideWithValue(prefs)],
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: EveryThemeScope(
              theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
              child: const PanelSplit(
                maxWidth: 1400,
                panel: SizedBox.expand(key: Key('panel')),
                child: SizedBox(),
              ),
            ),
          ),
        ),
      );
      expect(tester.getSize(find.byKey(const Key('panel'))).width, 728);
      await tester.drag(find.byKey(const ValueKey('panel-divider')), const Offset(-100, 0));
      await tester.pump();
      expect(tester.getSize(find.byKey(const Key('panel'))).width, closeTo(828, 1));
      expect(double.parse(prefs['artifacts.panel_width']!), closeTo(828, 1));
      await tester.pump(const Duration(milliseconds: 500)); // let the double-tap timer lapse
    });
  });

  group('PPTX speaker notes', () {
    PptxSlide slide(String title, String notes) =>
        (title: title, bullets: const [], body: '', notes: notes, isTitle: false);
    const colors = (background: 'FFFFFF', title: '000000', text: '111111', accent: '6E56CF');

    test('slides with notes get notes pages under one notes master', () {
      final zip = ZipDecoder().decodeBytes(
        buildPptx(
          title: 'Deck',
          colors: colors,
          slides: [slide('One', 'Say hi <warmly>\nThen pause'), slide('Two', ''), slide('Three', 'Wrap up')],
        ),
      );
      final names = zip.files.map((f) => f.name).toSet();
      expect(
        names,
        containsAll([
          'ppt/notesMasters/notesMaster1.xml',
          'ppt/notesMasters/_rels/notesMaster1.xml.rels',
          'ppt/theme/theme2.xml',
          'ppt/notesSlides/notesSlide1.xml',
          'ppt/notesSlides/notesSlide3.xml',
        ]),
      );
      expect(names.contains('ppt/notesSlides/notesSlide2.xml'), isFalse);
      final notes = _file(zip, 'ppt/notesSlides/notesSlide1.xml');
      expect(notes, contains('<a:t>Say hi &lt;warmly&gt;</a:t>'));
      expect(notes, contains('<a:t>Then pause</a:t>'));
      expect(_file(zip, 'ppt/notesSlides/_rels/notesSlide3.xml.rels'), contains('../slides/slide3.xml'));
      expect(_file(zip, 'ppt/slides/_rels/slide1.xml.rels'), contains('../notesSlides/notesSlide1.xml'));
      expect(_file(zip, 'ppt/slides/_rels/slide2.xml.rels'), isNot(contains('notesSlide')));
      expect(_file(zip, 'ppt/presentation.xml'), contains('<p:notesMasterId r:id="rId6"/>'));
      expect(_file(zip, 'ppt/_rels/presentation.xml.rels'), contains('Id="rId6"'));
      final types = _file(zip, '[Content_Types].xml');
      expect(types, contains('/ppt/notesSlides/notesSlide3.xml'));
      expect(types, contains('/ppt/notesMasters/notesMaster1.xml'));
    });

    test('a deck without notes has no notes master', () {
      final zip = ZipDecoder().decodeBytes(buildPptx(title: 'D', colors: colors, slides: [slide('One', ' ')]));
      expect(zip.files.any((f) => f.name.contains('notes')), isFalse);
      expect(_file(zip, 'ppt/presentation.xml'), isNot(contains('notesMasterIdLst')));
    });
  });

  group('Artifacts page', () {
    late AppDatabase db;
    late ProviderContainer container;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      container = ProviderContainer(overrides: [databaseProvider.overrideWithValue(db)]);
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    test('lists artifacts across chats, newest chat and artifact first', () async {
      final repo = container.read(chatRepositoryProvider);
      Future<void> chat(String id, String title, List<MessagePart> parts, DateTime at) async {
        await repo.createConversationWithId(id: id, title: title, model: const ModelId('m'));
        await repo.saveMessage(
          Message(id: 'm-$id', conversationId: id, role: Role.assistant, parts: parts, createdAt: at),
        );
      }

      await chat('a', 'Old chat', [
        _call('create_artifact', {'id': 'r', 'title': 'Report', 'kind': 'markdown', 'content': 'x'}, '1'),
      ], DateTime(2026, 1));
      await chat('b', 'Plain chat', [const TextPart('hello')], DateTime(2026, 2));
      await chat('c', 'New chat', [
        _call('create_artifact', {'id': 'p', 'title': 'Page', 'kind': 'html', 'content': '<p>'}, '2'),
        _call('create_artifact', {'id': 's', 'title': 'Script', 'kind': 'code', 'content': 'x'}, '3'),
        _call('make_quiz', {'title': 'Q', 'questions': []}, '4'),
      ], DateTime(2026, 3));

      final ids = await repo.watchArtifactConversations().first;
      expect(ids.toSet(), {'a', 'c'});
      final library = await loadArtifactLibrary(repo, ['c', 'a']);
      expect(library.map((e) => (e.conversationId, e.artifact.title)), [
        ('c', 'Script'),
        ('c', 'Page'),
        ('a', 'Report'),
      ]);
      expect(library.where((e) => e.matches('old')).single.artifact.id, 'r');
      expect(library.where((e) => e.matches('web page')).single.artifact.id, 'p');
    });

    test('a pending open is taken by the chat\'s panel once', () {
      container.read(pendingArtifactOpenProvider)['chat-1'] = 'art-1';
      final sub = container.listen(artifactPanelProvider('chat-1'), (_, _) {});
      expect(sub.read(), isA<ArtifactTarget>().having((t) => t.artifactId, 'artifactId', 'art-1'));
      expect(container.read(pendingArtifactOpenProvider), isEmpty);
      sub.close();
    });
  });
}
