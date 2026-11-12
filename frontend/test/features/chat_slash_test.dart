import 'dart:async';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/artifacts/checks/tool_checks.dart';
import 'package:every_ai/features/chat/chat_providers.dart';
import 'package:every_ai/features/chat/data/chat_transport.dart';
import 'package:every_ai/features/chat/domain/chat_session.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/slash/chat_commands.dart';
import 'package:every_ai/features/slash/skills/skill_md.dart';
import 'package:every_ai/features/skills/skills_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Transport implements ChatTransport {
  final requests = <ChatRequest>[];

  @override
  Stream<ChatEvent> send(ChatRequest request, {Future<void>? cancel}) {
    requests.add(request);
    return Stream.fromIterable(const [TextDelta('ok'), TurnDone()]);
  }
}

class _Catalog extends CatalogController {
  @override
  ModelCatalog build() => builtInCatalog;
}

void main() {
  group('forced tools', () {
    test('every make-command names a tool the backend defines', () {
      const known = {
        'make_slides',
        'make_quiz',
        'make_flashcards',
        'render_diagram',
        'render_svg',
        'generate_image',
        'create_artifact',
      };
      expect(forcedTools.values.map((f) => f.tool).toSet(), known);
      for (final name in forcedTools.keys) {
        expect(chatBuiltIns.where((c) => c.name == name), hasLength(1), reason: name);
      }
    });
  });

  group('SkillMd', () {
    test('rejects what the Agent Skills format does not allow', () {
      String skill(String name, [String desc = 'Does it.', String body = 'Steps.']) =>
          '---\nname: $name\ndescription: $desc\n---\n$body';
      expect(() => SkillMd.parse('no front matter'), throwsFormatException);
      expect(() => SkillMd.parse(skill('Bad Name')), throwsFormatException);
      expect(() => SkillMd.parse(skill('-lead')), throwsFormatException);
      expect(() => SkillMd.parse(skill('a--b')), throwsFormatException);
      expect(() => SkillMd.parse(skill('a' * 65)), throwsFormatException);
      expect(() => SkillMd.parse(skill('ok', '')), throwsFormatException);
      expect(() => SkillMd.parse(skill('ok', 'x' * 1025)), throwsFormatException);
      expect(() => SkillMd.parse(skill('ok', 'Does it.', '')), throwsFormatException);
    });
  });

  group('the controller sends force_tool and skill context', () {
    late AppDatabase db;
    late _Transport transport;
    late ProviderContainer container;
    const id = 'conv-slash';

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      transport = _Transport();
      final prefs = await Preferences.load(db);
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(prefs),
          installedSkillsProvider.overrideWith(NoInstalledSkills.new),
          chatTransportProvider.overrideWithValue(transport),
          appToolCheckerProvider.overrideWithValue(const AppToolChecker()),
          modelCatalogProvider.overrideWith(_Catalog.new),
        ],
      );
      container.listen(chatSessionProvider(id), (_, _) {});
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });

    tearDown(() async {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      container.dispose();
      await db.close();
    });

    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 40));
    ChatController ctl() => container.read(chatSessionProvider(id).notifier);
    ChatSessionState state() => container.read(chatSessionProvider(id));

    test('skill context rides in the prompt, not in the saved message, and is used once', () async {
      ctl().stageContext('<skill name="x">Steps.</skill>');
      await ctl().send('write it');
      await settle();
      expect(transport.requests.last.prompt, startsWith('<skill name="x">Steps.</skill>'));
      expect(transport.requests.last.prompt, endsWith('write it'));
      expect(state().messages.first.plainText, 'write it');

      await ctl().send('again');
      await settle();
      expect(transport.requests.last.prompt, 'again');

      await ctl().send('direct', context: 'CTX');
      await settle();
      expect(transport.requests.last.prompt, 'CTX\n\ndirect');
    });
  });
}
