import 'package:every_ai/core/net/api_client.dart';
import 'package:every_ai/features/code/gateway_key.dart' show SecretStore;
import 'package:every_ai/features/remote/data/host_link.dart';
import 'package:every_ai/features/remote/data/remote_api.dart';
import 'package:every_ai/features/remote/data/remote_store.dart';
import 'package:every_ai/features/remote/remote_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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

  test("signing out drops this computer's hosting and this device's pairings", () async {
    final secrets = _MemoryStore();
    final store = RemoteStore(secrets);
    await store.saveHost(const HostRegistration(id: 'h1', name: 'Mac', token: 'rh_x', privateKey: 'cHJpdg=='));
    await store.savePaired([
      const PairedHost(
        hostId: 'h2',
        name: 'Other Mac',
        platform: 'macOS',
        hostPublicKey: 'a2V5',
        deviceId: 'd9',
        deviceToken: 'rd_x',
        privateKey: 'cHJpdg==',
        pairingId: 'p1',
      ).approve(),
    ]);
    final deleted = <String>[];
    final api = ApiClient(
      baseUrl: Uri.parse('http://backend/'),
      client: MockClient((req) async {
        if (req.method == 'DELETE') deleted.add(req.url.path);
        return http.Response('{}', 200);
      }),
    );
    final container = ProviderContainer(
      overrides: [
        remoteStoreProvider.overrideWithValue(store),
        remoteApiProvider.overrideWithValue(RemoteApi(api, authenticated: false)),
      ],
    );
    addTearDown(container.dispose);
    expect(await container.read(pairedHostsProvider.future), hasLength(1));

    await container.read(remoteHostingProvider.notifier).signedOut();
    await container.read(pairedHostsProvider.notifier).signedOut();

    expect(await store.host(), isNull);
    expect(await store.paired(), isEmpty);
    expect(container.read(remoteHostingProvider).host, isNull);
    expect(container.read(hasRemoteHostProvider), isFalse);
    expect(deleted, unorderedEquals(['/v1/remote/hosts/h1', '/v1/remote/devices/d9']));
  });

  test('pair requests read both notice shapes', () {
    final notice = PairRequest.fromJson({
      'type': 'pair_request',
      'pairing_id': 'p1',
      'decide_by': 1700000000,
      'device': {'id': 'd1', 'name': 'Phone', 'public_key': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='},
    })!;
    expect((notice.pairingId, notice.deviceId, notice.deviceName), ('p1', 'd1', 'Phone'));
    expect(notice.fingerprint, matches(RegExp(r'^[0-9A-F]{4}-')));
    final hello = PairRequest.fromJson({
      'pairing_id': 'p2',
      'decide_by': 1700000000,
      'device_id': 'd2',
      'device_name': 'Tablet',
      'public_key': 'bad',
    })!;
    expect((hello.deviceId, hello.deviceName, hello.fingerprint), ('d2', 'Tablet', 'invalid key'));
    expect(PairRequest.fromJson({'pairing_id': 'p3'}), isNull);
  });
}
