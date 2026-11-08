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

  /// Makes a vault; returns the recovery key to show once.
  Future<String> create(String passphrase, {KdfParams kdf = defaultKdf}) async {
    _require();
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
    return RecoveryKey.format(made.recoveryKey);
  }

  Future<void> unlock(String passphrase) => _unlock((c, h) => c.unlockWithPassphrase(h, passphrase));

  Future<void> unlockWithRecovery(String recoveryKey) =>
      _unlock((c, h) => c.unlockWithRecovery(h, RecoveryKey.parse(recoveryKey)));

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
    final u = _open();
    final c = await ref.read(vaultCryptoProvider.future);
    final store = await _store;
    final previous = u.manifest.items.where((i) => i.id == id).firstOrNull;
    final version = (previous?.version ?? 0) + 1;
    final item = c.encryptItem(
      u.key,
      u.header.vaultId,
      id,
      version,
      Uint8List.fromList(utf8.encode(jsonEncode(value))),
    );
    await store.saveItem(item);
    await _resign(u, [
      for (final i in u.manifest.items)
        if (i.id != id) i,
      (id: id, version: version, digest: c.digest(item.body.ct)),
    ]);
  }

  Future<void> remove(String id) async {
    final u = _open();
    await (await _store).deleteItem(id);
    await _resign(u, [
      for (final i in u.manifest.items)
        if (i.id != id) i,
    ]);
  }

  Future<void> _resign(VaultUnlocked u, List<ManifestEntry> items) async {
    final c = await ref.read(vaultCryptoProvider.future);
    final store = await _store;
    final next = Manifest(vaultId: u.header.vaultId, version: u.manifest.version + 1, items: items);
    await store.saveManifest(next.bytes(), c.signManifest(u.key, u.header, next));
    await store.saveSeen(next.version);
    if (ref.mounted && identical(state, u)) state = VaultUnlocked(u.header, u.key, next);
  }

  /// [id]'s value; refused when its file doesn't match the signed manifest.
  Future<Map<String, Object?>?> get(String id) async {
    final u = _open();
    final c = await ref.read(vaultCryptoProvider.future);
    final entry = u.manifest.items.where((i) => i.id == id).firstOrNull;
    if (entry == null) return null;
    final item = await (await _store).item(id);
    if (item == null || item.version != entry.version || c.digest(item.body.ct) != entry.digest) {
      throw const VaultFormatError('the item does not match the signed manifest');
    }
    return jsonDecode(utf8.decode(c.decryptItem(u.key, u.header.vaultId, item))) as Map<String, Object?>;
  }
}
