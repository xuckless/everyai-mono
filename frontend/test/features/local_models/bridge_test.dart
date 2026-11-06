// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/code/gateway_key.dart';
import 'package:every_ai/features/local_models/local_model_bridge.dart';
import 'package:every_ai/features/models/domain/local_routes.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/settings/byok_keys.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Store implements SecretStore {
  _Store([Map<String, String>? values]) : values = values ?? {};
  final Map<String, String> values;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

ModelSpec _local(String name) =>
    ModelSpec(id: ModelId('local/$name'), provider: ModelProvider.of('local'), name: name, free: true);

const _qwen = LocalRoute(baseUrl: 'http://127.0.0.1:11434/v1', name: 'qwen3.5:9b', contextTokens: 32768, tools: true);
const _apple = LocalRoute(baseUrl: 'http://127.0.0.1:40001/v1', name: 'system', contextTokens: 4096);

void main() {
  tearDown(() {
    LocalRoutes.current = const {};
    LocalRoutes.aux = null;
  });

  group('chatTurnHeaders', () {
    test('a credit turn gets nothing, so it stays on our server', () {
      LocalRoutes.aux = _apple;
      expect(chatTurnHeaders('anthropic/claude-haiku-5.5', const {}), isEmpty);
    });

    test('a local turn says where its model is and what runs the side jobs', () {
      LocalRoutes.current = {'local/qwen3.5:9b': _qwen};
      LocalRoutes.aux = _apple;
      final h = chatTurnHeaders('local/qwen3.5:9b', const {});
      expect(h['X-Local-Base-Url'], 'http://127.0.0.1:11434/v1');
      expect(h['X-Local-Caps'], 'tools');
      expect(h['X-Local-Context'], '32768');
      expect(h['X-Local-Aux-Model'], 'local/system');
    });

    test('an OpenRouter key runs the side jobs itself; an Anthropic key does not', () {
      LocalRoutes.aux = _apple;
      expect(
        chatTurnHeaders('openai/gpt-6.1', const {'X-Provider-Key-OpenRouter': 'k'}),
        isNot(contains('X-Local-Aux-Model')),
      );
      expect(
        chatTurnHeaders('anthropic/claude-haiku-5.5', const {'X-Provider-Key-Anthropic': 'k'}),
        containsPair('X-Local-Aux-Model', 'local/system'),
      );
    });
  });

  group('catalog', () {
    late AppDatabase db;
    setUp(() => db = AppDatabase(NativeDatabase.memory()));
    tearDown(() => db.close());

    Future<ProviderContainer> container(List<ModelSpec> local, {Map<String, String>? keys}) async {
      final prefs = await Preferences.load(db);
      final c = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(prefs),
          secretStoreProvider.overrideWithValue(_Store(keys)),
          localModelSpecsProvider.overrideWithValue(local),
          // The catalog refresh must not reach a server.
          modelCatalogProvider.overrideWith(_OfflineCatalog.new),
        ],
      );
      addTearDown(c.dispose);
      await c.read(byokKeysProvider.future);
      return c;
    }

    test('local models join the catalog; Apple\'s model is the default when it is there', () async {
      final c = await container([_local('system'), _local('qwen3.5:9b')]);
      final catalog = c.read(modelCatalogProvider);
      expect(catalog[const ModelId('local/qwen3.5:9b')], isNotNull);
      expect(catalog.defaultModel.id, appleModelId);
      expect(c.read(defaultModelProvider).id, appleModelId);
    });

    test('without Apple\'s model and with no key, the smallest local model is the default', () async {
      LocalRoutes.aux = _qwen;
      final c = await container([_local('qwen3.5:9b')]);
      expect(c.read(modelCatalogProvider).defaultModel.id, const ModelId('local/qwen3.5:9b'));
    });

    test('with a key, the default stays the backend\'s', () async {
      LocalRoutes.aux = _qwen;
      final c = await container([_local('qwen3.5:9b')], keys: {'byok.openrouter': 'sk-or-x'});
      expect(c.read(modelCatalogProvider).defaultModel.id, defaultModelId);
    });

    test('Chat needs a model only with no key and no local model', () async {
      expect((await container(const [])).read(chatNeedsModelProvider), isTrue);
      expect((await container([_local('system')])).read(chatNeedsModelProvider), isFalse);
      expect((await container(const [], keys: {'byok.openrouter': 'sk-or-x'})).read(chatNeedsModelProvider), isFalse);
    });
  });
}

/// The catalog without its network refresh.
final class _OfflineCatalog extends CatalogController {
  @override
  Future<void> refresh() async {}
}
