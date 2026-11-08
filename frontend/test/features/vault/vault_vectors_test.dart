// The vectors are JSON read as dynamic.
// ignore_for_file: avoid_dynamic_calls

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:every_ai/features/vault/domain/vault_format.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

/// docs/vault/vectors.json comes from libsodium (make_vectors.py); every
/// byte here must match it.
void main() {
  late SodiumSumo sodium;
  late VaultCrypto c;
  late Map<String, dynamic> v;
  Uint8List b(Object? s) => base64.decode(s! as String);
  SecureKey key(Object? s) => SecureKey.fromList(sodium, b(s));

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
    c = VaultCrypto(sodium);
    v = jsonDecode(File('../docs/vault/vectors.json').readAsStringSync()) as Map<String, dynamic>;
  });

  test('the passphrase and recovery keys wrap the vault key byte for byte', () {
    final id = v['vault_id'] as String;
    final kdf = KdfParams(ops: v['kdf']['ops'] as int, mem: v['kdf']['mem'] as int);
    final kek = c.passphraseKek(utf8.decode(b(v['kdf']['passphrase_utf8'])), b(v['kdf']['salt']), kdf);
    expect(kek.extractBytes(), b(v['kdf']['kek']));
    final pw = c.seal(b(v['vault_key']), kek, aadOf(['wrap', 'password', id]), nonce: b(v['password_wrap']['nonce']));
    expect(pw.ct, b(v['password_wrap']['ct']));
    expect(aadOf(['wrap', 'password', id]), b(v['password_wrap']['aad']));

    final kekR = c.recoveryKek(b(v['recovery']['key']));
    expect(kekR.extractBytes(), b(v['recovery']['kek']));
    final rec = c.seal(b(v['vault_key']), kekR, aadOf(['wrap', 'recovery', id]), nonce: b(v['recovery']['nonce']));
    expect(rec.ct, b(v['recovery']['ct']));

    final vk = key(v['vault_key']);
    final sig = c.seal(b(v['signing']['seed']), vk, aadOf(['wrap', 'signing', id]), nonce: b(v['signing']['nonce']));
    expect(sig.ct, b(v['signing']['ct']));
    expect(sodium.crypto.sign.seedKeyPair(key(v['signing']['seed'])).publicKey, b(v['signing']['public']));

    // A header built from the vectors unlocks with both, and refuses a wrong passphrase.
    final header = VaultHeader.fromJson({
      'v': 1,
      'vault_id': id,
      'kdf': {'alg': 'argon2id13', 'ops': kdf.ops, 'mem': kdf.mem, 'salt': v['kdf']['salt']},
      'password': {'nonce': v['password_wrap']['nonce'], 'ct': v['password_wrap']['ct']},
      'recovery': {'nonce': v['recovery']['nonce'], 'ct': v['recovery']['ct']},
      'signing': {'public': v['signing']['public'], 'nonce': v['signing']['nonce'], 'ct': v['signing']['ct']},
    });
    expect(
      c.unlockWithPassphrase(header, utf8.decode(b(v['kdf']['passphrase_utf8']))).extractBytes(),
      b(v['vault_key']),
    );
    expect(c.unlockWithRecovery(header, b(v['recovery']['key'])).extractBytes(), b(v['vault_key']));
    expect(() => c.unlockWithPassphrase(header, 'wrong'), throwsA(isA<VaultAuthError>()));
    expect(RecoveryKey.parse(RecoveryKey.format(b(v['recovery']['key']))), b(v['recovery']['key']));
  });

  test('items, the signed manifest and a device join match libsodium', () {
    final id = v['vault_id'] as String;
    final vk = key(v['vault_key']);
    final i = v['item'] as Map<String, dynamic>;
    final item = c.encryptItem(
      vk,
      id,
      i['id'] as String,
      i['version'] as int,
      b(i['plaintext']),
      itemKey: b(i['key']),
      keyNonce: b(i['key_nonce']),
      bodyNonce: b(i['nonce']),
    );
    expect(item.key.ct, b(i['key_ct']));
    expect(item.body.ct, b(i['ct']));
    expect(c.decryptItem(vk, id, item), b(i['plaintext']));
    // The same body under another version is refused (AAD binds id + version).
    final moved = VaultItem(id: item.id, version: item.version + 1, key: item.key, body: item.body);
    expect(() => c.decryptItem(vk, id, moved), throwsA(isA<VaultAuthError>()));

    final m = Manifest(
      vaultId: id,
      version: 7,
      items: [(id: item.id, version: item.version, digest: c.digest(item.body.ct))],
    );
    expect(m.bytes(), b(v['manifest']['bytes']));
    final header = VaultHeader(
      vaultId: id,
      kdf: defaultKdf,
      salt: Uint8List(16),
      password: Sealed(Uint8List(24), Uint8List(48)),
      recovery: Sealed(Uint8List(24), Uint8List(48)),
      signingPublic: b(v['signing']['public']),
      signing: Sealed(b(v['signing']['nonce']), b(v['signing']['ct'])),
    );
    final signature = c.signManifest(vk, header, m);
    expect(signature, b(v['manifest']['signature']));
    expect(c.verifyManifest(header, m.bytes(), signature, minVersion: 7).version, 7);
    expect(() => c.verifyManifest(header, m.bytes(), signature, minVersion: 8), throwsA(isA<VaultFormatError>()));
    final edited = Uint8List.fromList(m.bytes())..[10] ^= 1;
    expect(() => c.verifyManifest(header, edited, signature), throwsA(isA<VaultAuthError>()));

    final j = v['join'] as Map<String, dynamic>;
    final approver = KeyPair(publicKey: b(j['approver_public']), secretKey: key(j['approver_secret']));
    final device = KeyPair(publicKey: b(j['device_public']), secretKey: key(j['device_secret']));
    final sent = c.sealForJoin(vk, id, device.publicKey, approver: approver, nonce: b(j['nonce']));
    expect(sent.sealed.ct, b(j['ct']));
    expect(c.openJoin(id, device, sent.approverPublic, sent.sealed).extractBytes(), b(v['vault_key']));
    expect(VaultCrypto.confirmCodeOf(sodium, approver.publicKey, device.publicKey), j['confirm']);
  });

  test('a new vault round-trips; the decoders only ever throw their own errors (fuzzed)', () {
    final made = c.create('v-test', 'a long passphrase', kdf: const KdfParams(ops: 1, mem: 8 << 20));
    final json = jsonEncode(made.header.toJson());
    final header = VaultHeader.fromJson(jsonDecode(json));
    expect(c.unlockWithPassphrase(header, 'a long passphrase').extractBytes(), made.vaultKey.extractBytes());
    final item = c.encryptItem(made.vaultKey, 'v-test', 'k', 1, Uint8List.fromList(utf8.encode('secret')));
    final itemJson = jsonEncode(item.toJson());

    final rnd = Random(42);
    for (var n = 0; n < 3000; n++) {
      final src = n.isEven ? json : itemJson;
      final bytes = utf8.encode(src).toList();
      // Flip, drop or insert a few bytes.
      for (var k = 0; k < 1 + rnd.nextInt(4); k++) {
        final at = rnd.nextInt(bytes.length);
        switch (rnd.nextInt(3)) {
          case 0:
            bytes[at] = rnd.nextInt(256);
          case 1:
            bytes.removeAt(at);
          default:
            bytes.insert(at, rnd.nextInt(128));
        }
      }
      Object? parsed;
      try {
        parsed = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      } on FormatException {
        continue; // not JSON: never reaches the decoders
      }
      try {
        if (n.isEven) {
          VaultHeader.fromJson(parsed);
        } else {
          c.decryptItem(made.vaultKey, 'v-test', VaultItem.fromJson(parsed));
        }
      } on VaultFormatError {
        // refused
      } on VaultAuthError {
        // tampered
      }
    }
    for (var n = 0; n < 500; n++) {
      final junk = Uint8List.fromList(List.generate(rnd.nextInt(80), (_) => rnd.nextInt(256)));
      try {
        Manifest.parse(junk);
      } on VaultFormatError {
        // refused
      }
    }
  });
}
