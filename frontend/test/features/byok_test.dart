import 'package:every_ai/core/config/billing_flag.dart';
import 'package:every_ai/features/code/gateway_key.dart';
import 'package:every_ai/features/settings/byok_keys.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/settings/domain/byok_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _MemoryStore implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  // Written for metered credits; the parked default has billing_parked_test.dart.
  setUp(() => BillingFlag.enabled = true);
  tearDown(() => BillingFlag.enabled = false);

  test('keys go to the keychain under byok.<id>', () async {
    final store = _MemoryStore()..values['byok.openrouter'] = 'sk-or-v1-abcdefgh1234';
    final c = ProviderContainer(overrides: [secretStoreProvider.overrideWithValue(store)]);
    addTearDown(c.dispose);
    expect(await c.read(byokKeysProvider.future), {'openrouter': 'sk-or-v1-abcdefgh1234'});
    await c.read(byokKeysProvider.notifier).save('anthropic', '  sk-ant-xyz9876 ');
    expect(store.values['byok.anthropic'], 'sk-ant-xyz9876');
    await c.read(byokKeysProvider.notifier).remove('openrouter');
    expect(store.values.containsKey('byok.openrouter'), isFalse);
    expect(c.read(byokKeysProvider).value, {'anthropic': 'sk-ant-xyz9876'});
    await c.read(byokKeysProvider.notifier).save('anthropic', '');
    expect(store.values, isEmpty);
    expect(ByokKeys.lastFour('sk-ant-xyz9876'), '9876');
  });

  group('ModelBilling', () {
    const claude = ModelId('anthropic/claude-haiku-5.5');
    const gpt = ModelId('openai/gpt-6.1-sol');
    const both = ModelBilling(keys: {'openrouter': 'sk-or-v1-k', 'anthropic': 'sk-ant-k'});

    test('by default the most specific key pays, and only its header goes out', () {
      expect(both.billerFor(claude).id, 'anthropic');
      expect(both.headersFor(claude), {'X-Provider-Key-Anthropic': 'sk-ant-k'});
      expect(both.headersFor(gpt), {'X-Provider-Key-OpenRouter': 'sk-or-v1-k'});
    });

    test('a pick holds while its key exists, and falls back once it is removed', () {
      final picked = ModelBilling(keys: both.keys, choices: {claude.value: 'openrouter', gpt.value: 'everyai'});
      expect(picked.headersFor(claude), {'X-Provider-Key-OpenRouter': 'sk-or-v1-k'});
      expect(picked.headersFor(gpt), isEmpty);
      final gone = ModelBilling(keys: const {'anthropic': 'sk-ant-k'}, choices: picked.choices);
      expect(gone.billerFor(claude).id, 'anthropic');
    });
  });
}
