import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/artifacts/artifact_providers.dart';
import 'package:every_ai/features/artifacts/checks/tool_checks.dart';
import 'package:every_ai/features/artifacts/domain/artifact.dart';
import 'package:every_ai/features/chat/chat_providers.dart';
import 'package:every_ai/features/chat/data/chat_transport.dart';
import 'package:every_ai/features/chat/domain/message.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/skills/skills_providers.dart';
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
          installedSkillsProvider.overrideWith(NoInstalledSkills.new),
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
}
