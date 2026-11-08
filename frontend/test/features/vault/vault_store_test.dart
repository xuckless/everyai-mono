import 'dart:io';

import 'package:every_ai/features/vault/data/vault_store.dart';
import 'package:every_ai/features/vault/domain/vault_format.dart';
import 'package:every_ai/features/vault/domain/vault_state.dart';
import 'package:every_ai/features/vault/vault_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late ProviderContainer c;
  const fast = KdfParams(ops: 1, mem: 8 << 20);

  setUp(() async {
    VaultDev.enabled = true;
    dir = await Directory.systemTemp.createTemp('vault_test');
    c = ProviderContainer(overrides: [vaultStoreProvider.overrideWith((ref) async => VaultStore(dir))]);
    c.read(vaultProvider);
    await Future<void>.delayed(Duration.zero);
  });
  tearDown(() async {
    c.dispose();
    VaultDev.enabled = false;
    await dir.delete(recursive: true);
  });

  VaultController vault() => c.read(vaultProvider.notifier);

  test('create, write, lock, unlock: wrong passphrase fails, the recovery key works', () async {
    expect(c.read(vaultProvider), isA<VaultAbsent>());
    final recovery = await vault().create('a long passphrase', kdf: fast);
    expect(recovery, startsWith('EV1-'));
    await vault().put('github', {'user': 'ada', 'token': 'ghp_x'});
    expect(await vault().get('github'), {'user': 'ada', 'token': 'ghp_x'});
    await vault().put('github', {'user': 'ada', 'token': 'ghp_y'});

    vault().lock();
    expect(c.read(vaultProvider), isA<VaultLocked>());
    expect(() => vault().get('github'), throwsStateError);
    await vault().unlock('wrong');
    expect(c.read(vaultProvider), isA<VaultFailed>().having((s) => s.header, 'header', isNotNull));
    await vault().unlock('a long passphrase');
    expect(c.read(vaultProvider), isA<VaultUnlocked>());
    expect((await vault().get('github'))!['token'], 'ghp_y');

    vault().lock();
    await vault().unlockWithRecovery(recovery.toLowerCase());
    expect(c.read(vaultProvider), isA<VaultUnlocked>());
  });

  test('a swapped item and a rolled-back manifest are refused', () async {
    await vault().create('a long passphrase', kdf: fast);
    await vault().put('a', {'n': 1});
    final store = VaultStore(dir);
    final oldManifest = (await store.manifest())!;
    final oldItem = await File('${dir.path}/items/a.json').readAsString();
    await vault().put('a', {'n': 2});

    // The server (or anyone with the files) puts the old item back: it no longer matches the manifest.
    await File('${dir.path}/items/a.json').writeAsString(oldItem);
    await expectLater(vault().get('a'), throwsA(isA<VaultFormatError>()));

    // The old, validly signed manifest is put back too: this device saw a newer one.
    await store.saveManifest(oldManifest.bytes, oldManifest.signature);
    vault().lock();
    await vault().unlock('a long passphrase');
    expect(c.read(vaultProvider), isA<VaultFailed>().having((s) => s.reason, 'reason', contains('older')));
  });

  test('without VAULT_DEV nothing runs', () async {
    VaultDev.enabled = false;
    await expectLater(vault().create('x', kdf: fast), throwsStateError);
  });
}
