import 'package:every_ai/features/code/gateway_key.dart';
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
  late _MemoryStore store;
  late int minted;
  Future<String> mint() async => 'sk-eai-new-${++minted}';

  setUp(() {
    store = _MemoryStore();
    minted = 0;
  });

  test('reads the keychain before minting, and mints once for concurrent callers', () async {
    store.values[GatewayKeys.storeKey] = 'sk-eai-kept';
    expect(await GatewayKeys(store: store, mint: mint).key(), 'sk-eai-kept');

    final fresh = GatewayKeys(store: _MemoryStore(), mint: mint);
    final both = await Future.wait([fresh.key(), fresh.key()]);
    expect(both, ['sk-eai-new-1', 'sk-eai-new-1']);
    expect(minted, 1);
  });

  test('remint replaces a refused key once, however many callers saw it', () async {
    store.values[GatewayKeys.storeKey] = 'sk-eai-revoked';
    final keys = GatewayKeys(store: store, mint: mint);
    final stale = await keys.key();
    final again = await Future.wait([keys.remint(stale), keys.remint(stale)]);
    expect(again, ['sk-eai-new-1', 'sk-eai-new-1']);
    expect(store.values[GatewayKeys.storeKey], 'sk-eai-new-1');
    // A caller still holding the old key gets the new one without another mint.
    expect(await keys.remint(stale), 'sk-eai-new-1');
    expect(minted, 1);
  });
}
