import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart';

/// The EveryAI vault format v1 (`docs/vault/format.md`), on libsodium. Pure
/// functions over a [SodiumSumo]; the files and the lock state are
/// `vault_store.dart`'s. Every decoder is strict: anything off is a
/// [VaultFormatError], never a partial value.
const vaultDomain = 'everyai-vault/v1';

/// Real vaults: Argon2id with 3 passes over 64 MiB (above OWASP's minimum).
const defaultKdf = KdfParams(ops: 3, mem: 64 << 20);

final class VaultFormatError implements Exception {
  const VaultFormatError(this.message);
  final String message;
  @override
  String toString() => 'VaultFormatError: $message';
}

/// A wrong passphrase, recovery key or a tampered blob: the AEAD refused it.
final class VaultAuthError implements Exception {
  const VaultAuthError(this.what);
  final String what;
  @override
  String toString() => 'VaultAuthError: $what did not verify';
}

Uint8List aadOf(List<Object> parts) => Uint8List.fromList(utf8.encode([vaultDomain, ...parts].join('|')));

final class KdfParams {
  const KdfParams({required this.ops, required this.mem});
  final int ops;
  final int mem;
}

/// A nonce and the ciphertext (tag included) it sealed.
final class Sealed {
  const Sealed(this.nonce, this.ct);
  final Uint8List nonce;
  final Uint8List ct;

  Map<String, Object?> toJson() => {'nonce': base64.encode(nonce), 'ct': base64.encode(ct)};

  static Sealed fromJson(Object? j, String what) {
    if (j is! Map) throw VaultFormatError('$what is not an object');
    final nonce = _bytes(j['nonce'], '$what.nonce', length: 24);
    final ct = _bytes(j['ct'], '$what.ct');
    if (ct.length < 16) throw VaultFormatError('$what.ct is too short');
    return Sealed(nonce, ct);
  }
}

Uint8List _bytes(Object? v, String what, {int? length}) {
  if (v is! String) throw VaultFormatError('$what is missing');
  final Uint8List b;
  try {
    b = base64.decode(v);
  } on FormatException {
    throw VaultFormatError('$what is not base64');
  }
  if (length != null && b.length != length) throw VaultFormatError('$what is ${b.length} bytes, not $length');
  return b;
}

String _string(Object? v, String what) {
  if (v is! String || v.isEmpty) throw VaultFormatError('$what is missing');
  return v;
}

int _int(Object? v, String what) {
  if (v is! int || v < 0) throw VaultFormatError('$what is not a count');
  return v;
}

/// `vault.json`.
final class VaultHeader {
  const VaultHeader({
    required this.vaultId,
    required this.kdf,
    required this.salt,
    required this.password,
    required this.recovery,
    required this.signingPublic,
    required this.signing,
  });

  final String vaultId;
  final KdfParams kdf;
  final Uint8List salt;
  final Sealed password;
  final Sealed recovery;
  final Uint8List signingPublic;
  final Sealed signing;

  Map<String, Object?> toJson() => {
    'v': 1,
    'vault_id': vaultId,
    'kdf': {'alg': 'argon2id13', 'ops': kdf.ops, 'mem': kdf.mem, 'salt': base64.encode(salt)},
    'password': password.toJson(),
    'recovery': recovery.toJson(),
    'signing': {'public': base64.encode(signingPublic), ...signing.toJson()},
  };

  static VaultHeader fromJson(Object? j) {
    if (j is! Map) throw const VaultFormatError('the header is not an object');
    if (j['v'] != 1) throw VaultFormatError('unknown vault version ${j['v']}');
    final kdf = j['kdf'];
    if (kdf is! Map || kdf['alg'] != 'argon2id13') throw const VaultFormatError('unknown key derivation');
    final ops = _int(kdf['ops'], 'kdf.ops');
    final mem = _int(kdf['mem'], 'kdf.mem');
    if (ops < 1 || ops > 64 || mem < (8 << 10) || mem > (4 << 30)) {
      throw const VaultFormatError('kdf parameters out of range');
    }
    final signing = j['signing'];
    return VaultHeader(
      vaultId: _string(j['vault_id'], 'vault_id'),
      kdf: KdfParams(ops: ops, mem: mem),
      salt: _bytes(kdf['salt'], 'kdf.salt', length: 16),
      password: Sealed.fromJson(j['password'], 'password'),
      recovery: Sealed.fromJson(j['recovery'], 'recovery'),
      signingPublic: _bytes(signing is Map ? signing['public'] : null, 'signing.public', length: 32),
      signing: Sealed.fromJson(signing, 'signing'),
    );
  }
}

/// One encrypted item: its key under the vault key, its body under its key.
final class VaultItem {
  const VaultItem({required this.id, required this.version, required this.key, required this.body});
  final String id;
  final int version;
  final Sealed key;
  final Sealed body;

  Map<String, Object?> toJson() => {
    'v': 1,
    'id': id,
    'version': version,
    'key_nonce': base64.encode(key.nonce),
    'key_ct': base64.encode(key.ct),
    'nonce': base64.encode(body.nonce),
    'ct': base64.encode(body.ct),
  };

  static VaultItem fromJson(Object? j) {
    if (j is! Map) throw const VaultFormatError('the item is not an object');
    if (j['v'] != 1) throw VaultFormatError('unknown item version ${j['v']}');
    return VaultItem(
      id: _string(j['id'], 'id'),
      version: _int(j['version'], 'version'),
      key: Sealed.fromJson({'nonce': j['key_nonce'], 'ct': j['key_ct']}, 'item key'),
      body: Sealed.fromJson({'nonce': j['nonce'], 'ct': j['ct']}, 'item body'),
    );
  }
}

typedef ManifestEntry = ({String id, int version, String digest});

/// The signed list of items: the server can't drop, swap or roll one back unseen.
final class Manifest {
  const Manifest({required this.vaultId, required this.version, required this.items});
  final String vaultId;
  final int version;
  final List<ManifestEntry> items;

  /// Canonical bytes (what is signed): fixed key order, items by id, no spaces.
  Uint8List bytes() {
    final sorted = [...items]..sort((a, b) => a.id.compareTo(b.id));
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'v': 1,
          'vault_id': vaultId,
          'version': version,
          'items': [
            for (final i in sorted) {'id': i.id, 'version': i.version, 'digest': i.digest},
          ],
        }),
      ),
    );
  }

  static Manifest parse(Uint8List bytes) {
    final Object? j;
    try {
      j = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const VaultFormatError('the manifest is not JSON');
    }
    if (j is! Map || j['v'] != 1) throw const VaultFormatError('unknown manifest version');
    final items = j['items'];
    if (items is! List) throw const VaultFormatError('manifest items missing');
    return Manifest(
      vaultId: _string(j['vault_id'], 'vault_id'),
      version: _int(j['version'], 'version'),
      items: [
        for (final i in items)
          if (i is Map)
            (
              id: _string(i['id'], 'item id'),
              version: _int(i['version'], 'item version'),
              digest: _string(i['digest'], 'digest'),
            )
          else
            throw const VaultFormatError('a manifest item is not an object'),
      ],
    );
  }
}

/// The vault's operations on one libsodium instance.
final class VaultCrypto {
  VaultCrypto(this.sodium);
  final SodiumSumo sodium;

  Uint8List random(int n) => sodium.randombytes.buf(n);

  SecureKey _key(Uint8List bytes) => SecureKey.fromList(sodium, bytes);

  Sealed seal(Uint8List message, SecureKey key, Uint8List aad, {Uint8List? nonce}) {
    final n = nonce ?? random(24);
    return Sealed(
      n,
      sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(message: message, nonce: n, key: key, additionalData: aad),
    );
  }

  Uint8List open(Sealed s, SecureKey key, Uint8List aad, String what) {
    try {
      return sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
        cipherText: s.ct,
        nonce: s.nonce,
        key: key,
        additionalData: aad,
      );
    } on SodiumException {
      throw VaultAuthError(what);
    }
  }

  SecureKey passphraseKek(String passphrase, Uint8List salt, KdfParams kdf) => sodium.crypto.pwhash.callRaw(
    outLen: 32,
    password: Int8List.fromList(utf8.encode(passphrase)),
    salt: salt,
    opsLimit: kdf.ops,
    memLimit: kdf.mem,
  );

  SecureKey recoveryKek(Uint8List recoveryKey) {
    final rk = _key(recoveryKey);
    try {
      return _key(
        sodium.crypto.genericHash(
          message: Uint8List.fromList(utf8.encode('$vaultDomain|recovery')),
          outLen: 32,
          key: rk,
        ),
      );
    } finally {
      rk.dispose();
    }
  }

  /// A new vault: the header, its vault key (keep it only while unlocked) and
  /// the recovery key (show it once).
  ({VaultHeader header, SecureKey vaultKey, Uint8List recoveryKey}) create(
    String vaultId,
    String passphrase, {
    KdfParams kdf = defaultKdf,
  }) {
    final vk = _key(random(32));
    final salt = random(16);
    final rk = random(32);
    final seed = random(32);
    final kek = passphraseKek(passphrase, salt, kdf);
    final kekR = recoveryKek(rk);
    final pair = sodium.crypto.sign.seedKeyPair(_key(seed));
    final vkBytes = vk.extractBytes();
    final header = VaultHeader(
      vaultId: vaultId,
      kdf: kdf,
      salt: salt,
      password: seal(vkBytes, kek, aadOf(['wrap', 'password', vaultId])),
      recovery: seal(vkBytes, kekR, aadOf(['wrap', 'recovery', vaultId])),
      signingPublic: pair.publicKey,
      signing: seal(seed, vk, aadOf(['wrap', 'signing', vaultId])),
    );
    kek.dispose();
    kekR.dispose();
    pair.secretKey.dispose();
    return (header: header, vaultKey: vk, recoveryKey: rk);
  }

  SecureKey unlockWithPassphrase(VaultHeader h, String passphrase) {
    final kek = passphraseKek(passphrase, h.salt, h.kdf);
    try {
      return _key(open(h.password, kek, aadOf(['wrap', 'password', h.vaultId]), 'the passphrase'));
    } finally {
      kek.dispose();
    }
  }

  SecureKey unlockWithRecovery(VaultHeader h, Uint8List recoveryKey) {
    final kek = recoveryKek(recoveryKey);
    try {
      return _key(open(h.recovery, kek, aadOf(['wrap', 'recovery', h.vaultId]), 'the recovery key'));
    } finally {
      kek.dispose();
    }
  }

  VaultItem encryptItem(
    SecureKey vk,
    String vaultId,
    String id,
    int version,
    Uint8List plaintext, {
    Uint8List? itemKey,
    Uint8List? keyNonce,
    Uint8List? bodyNonce,
  }) {
    final ikBytes = itemKey ?? random(32);
    final ik = _key(ikBytes);
    try {
      return VaultItem(
        id: id,
        version: version,
        key: seal(ikBytes, vk, aadOf(['item-key', vaultId, id, version]), nonce: keyNonce),
        body: seal(plaintext, ik, aadOf(['item', vaultId, id, version]), nonce: bodyNonce),
      );
    } finally {
      ik.dispose();
    }
  }

  Uint8List decryptItem(SecureKey vk, String vaultId, VaultItem item) {
    final ik = _key(open(item.key, vk, aadOf(['item-key', vaultId, item.id, item.version]), 'item ${item.id} key'));
    try {
      return open(item.body, ik, aadOf(['item', vaultId, item.id, item.version]), 'item ${item.id}');
    } finally {
      ik.dispose();
    }
  }

  String digest(Uint8List ct) =>
      sodium.crypto.genericHash(message: ct, outLen: 32).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  Uint8List _signed(Uint8List manifest) => Uint8List.fromList([...utf8.encode('$vaultDomain|manifest|'), ...manifest]);

  Uint8List signManifest(SecureKey vk, VaultHeader h, Manifest m) {
    final seed = _key(open(h.signing, vk, aadOf(['wrap', 'signing', h.vaultId]), 'the signing key'));
    final pair = sodium.crypto.sign.seedKeyPair(seed);
    try {
      return sodium.crypto.sign.detached(message: _signed(m.bytes()), secretKey: pair.secretKey);
    } finally {
      seed.dispose();
      pair.secretKey.dispose();
    }
  }

  /// The manifest, if it is signed by this vault and not older than
  /// [minVersion] (the highest this device verified: rollback is refused).
  Manifest verifyManifest(VaultHeader h, Uint8List bytes, Uint8List signature, {int minVersion = 0}) {
    if (signature.length != 64) throw const VaultFormatError('the signature is not 64 bytes');
    final ok = sodium.crypto.sign.verifyDetached(
      message: _signed(bytes),
      signature: signature,
      publicKey: h.signingPublic,
    );
    if (!ok) throw const VaultAuthError('the manifest signature');
    final m = Manifest.parse(bytes);
    if (m.vaultId != h.vaultId) throw const VaultFormatError("the manifest is another vault's");
    if (m.version < minVersion) {
      throw VaultFormatError('the manifest is older (${m.version}) than one seen ($minVersion)');
    }
    return m;
  }

  /// The 6 digits both devices show while one approves the other.
  static String confirmCodeOf(SodiumSumo sodium, Uint8List approverPublic, Uint8List devicePublic) {
    final h = sodium.crypto.genericHash(message: Uint8List.fromList([...approverPublic, ...devicePublic]), outLen: 32);
    final n = ByteData.sublistView(h, 0, 4).getUint32(0);
    return (n % 1000000).toString().padLeft(6, '0');
  }

  /// The approving side: seals the vault key for the joining device's
  /// `crypto_kx` public key with a fresh key pair of its own.
  ({Uint8List approverPublic, Sealed sealed}) sealForJoin(
    SecureKey vk,
    String vaultId,
    Uint8List devicePublic, {
    KeyPair? approver,
    Uint8List? nonce,
  }) {
    final pair = approver ?? sodium.crypto.kx.keyPair();
    final keys = sodium.crypto.kx.serverSessionKeys(
      serverPublicKey: pair.publicKey,
      serverSecretKey: pair.secretKey,
      clientPublicKey: devicePublic,
    );
    try {
      return (
        approverPublic: pair.publicKey,
        sealed: seal(vk.extractBytes(), keys.tx, aadOf(['join', vaultId]), nonce: nonce),
      );
    } finally {
      keys.rx.dispose();
      keys.tx.dispose();
    }
  }

  /// The joining side: opens the vault key with its own `crypto_kx` key pair.
  SecureKey openJoin(String vaultId, KeyPair device, Uint8List approverPublic, Sealed sealed) {
    final keys = sodium.crypto.kx.clientSessionKeys(
      clientPublicKey: device.publicKey,
      clientSecretKey: device.secretKey,
      serverPublicKey: approverPublic,
    );
    try {
      return _key(open(sealed, keys.rx, aadOf(['join', vaultId]), 'the join'));
    } finally {
      keys.rx.dispose();
      keys.tx.dispose();
    }
  }
}

/// `EV1-XXXX-XXXX-…`: the recovery key in Crockford base32 (no I, L, O, U).
abstract final class RecoveryKey {
  static const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  static String format(Uint8List key) {
    var bits = 0, value = 0;
    final out = StringBuffer();
    for (final b in key) {
      value = (value << 8) | b;
      bits += 8;
      while (bits >= 5) {
        out.write(_alphabet[(value >> (bits - 5)) & 31]);
        bits -= 5;
      }
    }
    if (bits > 0) out.write(_alphabet[(value << (5 - bits)) & 31]);
    final s = out.toString();
    return 'EV1-${[for (var i = 0; i < s.length; i += 4) s.substring(i, i + 4 > s.length ? s.length : i + 4)].join('-')}';
  }

  /// The 32 bytes back; case, spaces and dashes don't matter, and the
  /// look-alikes O/I/L read as 0/1/1.
  static Uint8List parse(String text) {
    var t = text.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
    if (!t.startsWith('EV1')) throw const VaultFormatError('a recovery key starts with EV1');
    t = t.substring(3).replaceAll('O', '0').replaceAll(RegExp('[IL]'), '1');
    var bits = 0, value = 0;
    final out = <int>[];
    for (final c in t.split('')) {
      final v = _alphabet.indexOf(c);
      if (v < 0) throw VaultFormatError('"$c" is not in a recovery key');
      value = ((value << 5) | v) & 0xFFFF;
      bits += 5;
      if (bits >= 8) {
        out.add((value >> (bits - 8)) & 0xFF);
        bits -= 8;
      }
    }
    if (out.length != 32) throw const VaultFormatError('a recovery key is 52 characters');
    return Uint8List.fromList(out);
  }
}
