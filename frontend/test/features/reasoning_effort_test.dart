import 'dart:async';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/artifacts/checks/tool_checks.dart';
import 'package:every_ai/features/chat/chat_providers.dart';
import 'package:every_ai/features/chat/data/chat_transport.dart';
import 'package:every_ai/features/chat/domain/reasoning_effort.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/skills/skills_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Transport implements ChatTransport {
  final requests = <ChatRequest>[];

  @override
  Stream<ChatEvent> send(ChatRequest request, {Future<void>? cancel}) {
    requests.add(request);
    return const Stream.empty();
  }
}

class _Catalog extends CatalogController {
  @override
  ModelCatalog build() => builtInCatalog;
}

void main() {
  test('wire values: auto sends nothing; models without reasoning get none', () {
    const plain = ModelSpec(id: ModelId('x/plain'), provider: ModelProvider.anthropic, name: 'Plain');
    const thinker = ModelSpec(
      id: ModelId('x/think'),
      provider: ModelProvider.anthropic,
      name: 'Think',
      reasoning: true,
    );
    expect(ReasoningEffort.auto.wire, isNull);
    expect(ReasoningEffort.max.wire, 'max');
    expect(ReasoningEffort.high.wireFor(thinker), 'high');
    expect(ReasoningEffort.high.wireFor(plain), isNull);
    expect(ReasoningEffort.parse('medium'), ReasoningEffort.medium);
    expect(ReasoningEffort.parse(null), ReasoningEffort.auto);
    expect(ReasoningEffort.parse('bogus'), ReasoningEffort.auto);
  });

  group('per conversation', () {
    late AppDatabase db;
    late Preferences prefs;
    late _Transport transport;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      prefs = await Preferences.load(db);
      transport = _Transport();
    });

    tearDown(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await db.close();
    });

    ProviderContainer open() {
      final c = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(prefs),
          installedSkillsProvider.overrideWith(NoInstalledSkills.new),
          chatTransportProvider.overrideWithValue(transport),
          chatClientToolsProvider.overrideWithValue(const {}),
          appToolCheckerProvider.overrideWithValue(const AppToolChecker()),
          modelCatalogProvider.overrideWith(_Catalog.new),
        ],
      );
      c.listen(chatSessionProvider('a'), (_, _) {});
      c.listen(chatSessionProvider('b'), (_, _) {});
      return c;
    }

    test('is kept per chat, survives a restart, and rides on the request', () async {
      var c = open();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      c.read(chatSessionProvider('a').notifier).setEffort(ReasoningEffort.high);
      expect(c.read(chatSessionProvider('a')).effort, ReasoningEffort.high);
      expect(c.read(chatSessionProvider('b')).effort, ReasoningEffort.auto);
      c.dispose();

      c = open();
      addTearDown(c.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c.read(chatSessionProvider('a')).effort, ReasoningEffort.high);
      await c.read(chatSessionProvider('a').notifier).send('Think hard');
      await c.read(chatSessionProvider('b').notifier).send('Quick one');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(transport.requests.map((r) => r.effort), ['high', null]);

      // Back to Auto clears the stored value.
      c.read(chatSessionProvider('a').notifier).setEffort(ReasoningEffort.auto);
      expect(prefs[ReasoningEffort.prefKey('a')], isNull);
    });
  });
}
