import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sodium/sodium_sumo.dart';

import 'data/vault_store.dart';
import 'domain/vault_format.dart';
import 'domain/vault_state.dart';

/// The vault is dev only (`--dart-define=VAULT_DEV=true`) until it has been
/// reviewed (docs/vault/format.md); release builds leave this false and show nothing.
abstract final class VaultDev {
  static bool enabled = const bool.fromEnvironment('VAULT_DEV');
}

final vaultStoreProvider = FutureProvider<VaultStore>(
  (ref) async => VaultStore(Directory('${(await getApplicationSupportDirectory()).path}/vault')),
);

final vaultCryptoProvider = FutureProvider<VaultCrypto>((ref) async => VaultCrypto(await SodiumSumoInit.init()));

final vaultProvider = NotifierProvider<VaultController, VaultState>(VaultController.new);

/// The local vault (V1): create, unlock, lock, and items in and out. Every
/// write re-signs the manifest with a higher version; every read checks the
/// item against it, so a swapped or rolled-back file is refused.
final class VaultController extends Notifier<VaultState> {
  Future<VaultStore> get _store => ref.read(vaultStoreProvider.future);

  /// The [load] or [unlock] under way: a second call joins it.
  Future<void>? _busy;

  @override
  VaultState build() {
    ref.onDispose(_dispose);
    if (VaultDev.enabled) _busy = _load().whenComplete(() => _busy = null);
    return const VaultAbsent();
  }

  /// The vault key while unlocked (also in [VaultUnlocked]), so disposal can zero it.
  SecureKey? _liveKey;

  void _dispose() {
    _liveKey?.dispose();
    _liveKey = null;
  }

  Future<void> _load() async {
    try {
      final h = await (await _store).header();
      if (!ref.mounted) return;
      state = h == null ? const VaultAbsent() : VaultLocked(h);
    } on Object catch (e) {
      if (ref.mounted) state = VaultFailed("The vault can't be read: $e");
    }
  }

  void _require() {
    if (!VaultDev.enabled) throw StateError('The vault is dev only (VAULT_DEV).');
  }

  /// The writes (create, put, remove) in order: each one reads the manifest
  /// the previous one left, so none drops another's item or reuses its
  /// manifest version.
  Future<void> _writes = Future.value();

  Future<T> _serial<T>(Future<T> Function() write) {
    final done = _writes.then((_) => write());
    _writes = done.then((_) {}, onError: (Object _) {});
    return done;
  }

  /// Makes a vault; returns the recovery key to show once.
  Future<String> create(String passphrase, {KdfParams kdf = defaultKdf}) async {
    _require();
    return _serial(() => _create(passphrase, kdf));
  }

  Future<String> _create(String passphrase, KdfParams kdf) async {
    final free = switch (state) {
      VaultAbsent() => true,
      VaultFailed(:final header) => header == null,
      _ => false,
    };
    if (!free) throw StateError('A vault exists already.');
    final c = await ref.read(vaultCryptoProvider.future);
    final id = 'v-${base64Url.encode(c.random(9))}';
    final made = c.create(id, passphrase, kdf: kdf);
    final store = await _store;
    await store.saveHeader(made.header);
    final manifest = Manifest(vaultId: id, version: 1, items: const []);
    await store.saveManifest(manifest.bytes(), c.signManifest(made.vaultKey, made.header, manifest));
    await store.saveSeen(1);
    _liveKey = made.vaultKey;
    state = VaultUnlocked(made.header, made.vaultKey, manifest);
    try {
      return RecoveryKey.format(made.recoveryKey);
    } finally {
      wipe(made.recoveryKey);
    }
  }

  Future<void> unlock(String passphrase) => _unlock((c, h) => c.unlockWithPassphrase(h, passphrase));

  Future<void> unlockWithRecovery(String recoveryKey) => _unlock((c, h) {
    final rk = RecoveryKey.parse(recoveryKey);
    try {
      return c.unlockWithRecovery(h, rk);
    } finally {
      wipe(rk);
    }
  });

  Future<void> _unlock(SecureKey Function(VaultCrypto c, VaultHeader h) open) {
    _require();
    return _busy ??= _doUnlock(open).whenComplete(() => _busy = null);
  }

  Future<void> _doUnlock(SecureKey Function(VaultCrypto c, VaultHeader h) open) async {
    final header = switch (state) {
      VaultLocked(:final header) => header,
      VaultFailed(:final header?) => header,
      _ => null,
    };
    if (header == null) return;
    state = VaultUnlocking(header);
    final c = await ref.read(vaultCryptoProvider.future);
    SecureKey? key;
    try {
      key = open(c, header);
      final store = await _store;
      final m = await store.manifest();
      if (m == null) throw const VaultFormatError('manifest.json is missing');
      final manifest = c.verifyManifest(header, m.bytes, m.signature, minVersion: await store.seenVersion());
      await store.saveSeen(manifest.version);
      if (!ref.mounted) return key.dispose();
      _liveKey = key;
      state = VaultUnlocked(header, key, manifest);
    } on VaultAuthError catch (e) {
      key?.dispose();
      if (!ref.mounted) return;
      state = VaultFailed(
        e.what == 'the manifest signature' ? 'The vault files were changed.' : 'That did not unlock the vault.',
        header: header,
      );
    } on VaultFormatError catch (e) {
      key?.dispose();
      if (!ref.mounted) return;
      state = VaultFailed('The vault files are damaged: ${e.message}', header: header);
    } on Object catch (e) {
      // A file that can't be read or isn't JSON: never stay unlocking with
      // the key out.
      key?.dispose();
      if (!ref.mounted) return;
      state = VaultFailed("The vault can't be read: $e", header: header);
    }
  }

  void lock() {
    if (state case VaultUnlocked(:final header, :final key)) {
      state = VaultLocking(header);
      key.dispose();
      _liveKey = null;
      state = VaultLocked(header);
    }
  }

  VaultUnlocked _open() => switch (state) {
    final VaultUnlocked u => u,
    _ => throw StateError('The vault is locked.'),
  };

  /// Writes [id] (a new version when it exists) and re-signs the manifest.
  Future<void> put(String id, Map<String, Object?> value) async {
    _open();
    return _serial(() async {
      final c = await ref.read(vaultCryptoProvider.future);
      final store = await _store;
      // Everything that needs the key happens here, with no await between
      // the state check and the last use: a lock meanwhile can't hand the
      // crypto a disposed key.
      final u = _open();
      final previous = u.manifest.items.where((i) => i.id == id).firstOrNull;
      final version = (previous?.version ?? 0) + 1;
      final plain = Uint8List.fromList(utf8.encode(jsonEncode(value)));
      final VaultItem item;
      try {
        item = c.encryptItem(u.key, u.header.vaultId, id, version, plain);
      } finally {
        wipe(plain);
      }
      final next = _next(c, u, [
        for (final i in u.manifest.items)
          if (i.id != id) i,
        (id: id, version: version, digest: c.digest(item.body.ct)),
      ]);
      await store.saveItem(item);
      await _commit(store, u, next);
    });
  }

  Future<void> remove(String id) async {
    _open();
    return _serial(() async {
      final c = await ref.read(vaultCryptoProvider.future);
      final store = await _store;
      final u = _open();
      final next = _next(c, u, [
        for (final i in u.manifest.items)
          if (i.id != id) i,
      ]);
      await store.deleteItem(id);
      await _commit(store, u, next);
    });
  }

  /// The next manifest and its signature (synchronous: see [put]).
  ({Manifest manifest, Uint8List signature}) _next(VaultCrypto c, VaultUnlocked u, List<ManifestEntry> items) {
    final next = Manifest(vaultId: u.header.vaultId, version: u.manifest.version + 1, items: items);
    return (manifest: next, signature: c.signManifest(u.key, u.header, next));
  }

  Future<void> _commit(VaultStore store, VaultUnlocked u, ({Manifest manifest, Uint8List signature}) next) async {
    await store.saveManifest(next.manifest.bytes(), next.signature);
    await store.saveSeen(next.manifest.version);
    if (!ref.mounted) return;
    // Still unlocked with the same key (not locked meanwhile): the state follows the files.
    if (state case VaultUnlocked(:final key) when identical(key, u.key)) {
      state = VaultUnlocked(u.header, u.key, next.manifest);
    }
  }

  /// [id]'s value; refused when its file doesn't match the signed manifest.
  /// In line with the writes, so a put half done isn't read as tampering.
  Future<Map<String, Object?>?> get(String id) async {
    _open();
    return _serial(() async {
      final c = await ref.read(vaultCryptoProvider.future);
      final store = await _store;
      final item = await store.item(id);
      // Checked after the read: a lock meanwhile disposed the key.
      final u = _open();
      final entry = u.manifest.items.where((i) => i.id == id).firstOrNull;
      if (entry == null) return null;
      if (item == null || item.version != entry.version || c.digest(item.body.ct) != entry.digest) {
        throw const VaultFormatError('the item does not match the signed manifest');
      }
      final plain = c.decryptItem(u.key, u.header.vaultId, item);
      try {
        return jsonDecode(utf8.decode(plain)) as Map<String, Object?>;
      } finally {
        wipe(plain);
      }
    });
  }
}
