import 'package:every_ai/features/code/gateway_key.dart' show SecretStore;
import 'package:every_ai/features/remote/data/remote_store.dart';
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

/// Auth without a keychain or server; the test moves it between states.
void main() {
  test('hosting and pairings survive a restart in the secret store', () async {
    final secrets = _MemoryStore();
    final store = RemoteStore(secrets);
    expect(await store.host(), isNull);
    expect(await store.paired(), isEmpty);

    const host = HostRegistration(
      id: 'h1',
      name: 'Mac',
      token: 'rh_x',
      privateKey: 'cHJpdg==',
      devices: {'d1': 'a2V5'},
    );
    await store.saveHost(host.copyWith(enabled: false));
    final loaded = (await store.host())!;
    expect((loaded.id, loaded.token, loaded.enabled), ('h1', 'rh_x', false));
    expect(loaded.devices, {'d1': 'a2V5'});
    await store.saveHost(null);
    expect(await store.host(), isNull);

    const paired = PairedHost(
      hostId: 'h1',
      name: 'Mac',
      platform: 'macOS',
      hostPublicKey: 'a2V5',
      deviceId: 'd1',
      deviceToken: 'rd_x',
      privateKey: 'cHJpdg==',
      pairingId: 'p1',
    );
    await store.savePaired([paired.approve()]);
    final again = (await store.paired()).single;
    expect((again.hostId, again.deviceToken, again.approved), ('h1', 'rd_x', true));
    // Nothing secret goes anywhere but the secret store.
    expect(secrets.values.keys.toList(), [RemoteStore.pairedKey]);
  });
}
