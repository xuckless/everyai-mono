import 'dart:convert';
import 'dart:typed_data';

import 'package:every_ai/features/remote/domain/remote_crypto.dart';
import 'package:every_ai/features/remote/domain/remote_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

Future<(SecureChannel client, SecureChannel host)> _pair(RemoteIdentity device, RemoteIdentity host) async {
  final hs = await ClientHandshake.start(device, host.publicKey);
  final (accept, hostChannel) = await acceptHandshake(host, device.publicKey, hs.init);
  return (await hs.finish(accept), hostChannel);
}

void main() {
  late RemoteIdentity device;
  late RemoteIdentity host;

  setUp(() async {
    device = await RemoteIdentity.generate();
    host = await RemoteIdentity.generate();
  });

  test('identities round-trip through their stored private key', () async {
    final again = await RemoteIdentity.restore(device.privateKeyBase64);
    expect(again.publicKey, device.publicKey);
    expect(decodePublicKey(device.publicKeyBase64), device.publicKey);
    expect(() => decodePublicKey(base64Encode([1, 2, 3])), throwsA(isA<RemoteCryptoError>()));
  });

  test('both directions open what the other side sealed, in order', () async {
    final (client, hostChannel) = await _pair(device, host);
    final up = await Future.wait([for (var i = 0; i < 5; i++) client.seal(utf8.encode('up $i'))]);
    final opened = <String>[];
    for (final f in up) {
      opened.add(utf8.decode(await hostChannel.open(f)));
    }
    expect(opened, ['up 0', 'up 1', 'up 2', 'up 3', 'up 4']);

    final down = await hostChannel.seal(utf8.encode('down'));
    expect(utf8.decode(await client.open(down)), 'down');
    // The ciphertext doesn't carry the plaintext.
    expect(utf8.decode(down, allowMalformed: true), isNot(contains('down')));
  });

  test('seal delivers frames in the order they were asked for', () async {
    final (client, hostChannel) = await _pair(device, host);
    final delivered = <Uint8List>[];
    await Future.wait([client.seal(Uint8List(50000), delivered.add), client.seal(utf8.encode('small'), delivered.add)]);
    expect(await hostChannel.open(delivered[0]), hasLength(50000));
    expect(utf8.decode(await hostChannel.open(delivered[1])), 'small');
  });

  test('a tampered frame fails to open', () async {
    final (client, hostChannel) = await _pair(device, host);
    final frame = await client.seal(utf8.encode('rm -rf build'));
    final tampered = Uint8List.fromList(frame)..[12] ^= 1;
    await expectLater(hostChannel.open(tampered), throwsA(isA<RemoteCryptoError>()));
    // A changed counter in the header is caught too (it is authenticated).
    final moved = Uint8List.fromList(frame)..[8] ^= 1;
    await expectLater(hostChannel.open(moved), throwsA(isA<RemoteCryptoError>()));
  });

  test('a replayed frame is refused', () async {
    final (client, hostChannel) = await _pair(device, host);
    final first = await client.seal(utf8.encode('one'));
    final second = await client.seal(utf8.encode('two'));
    await hostChannel.open(first);
    await hostChannel.open(second);
    await expectLater(hostChannel.open(first), throwsA(isA<RemoteCryptoError>()));
  });

  test('a host with other keys is caught at the handshake', () async {
    final impostor = await RemoteIdentity.generate();
    final hs = await ClientHandshake.start(device, host.publicKey);
    final (accept, _) = await acceptHandshake(impostor, device.publicKey, hs.init);
    await expectLater(hs.finish(accept), throwsA(isA<RemoteCryptoError>()));
  });

  test('a relay that swaps in its own device key gets nothing it can use', () async {
    final relay = await RemoteIdentity.generate();
    // The host believes the relay's key is the device's.
    final hs = await ClientHandshake.start(device, host.publicKey);
    final (accept, _) = await acceptHandshake(host, relay.publicKey, hs.init);
    await expectLater(hs.finish(accept), throwsA(isA<RemoteCryptoError>()));
  });

  test('each connection gets fresh keys', () async {
    final (a, _) = await _pair(device, host);
    final (_, hostB) = await _pair(device, host);
    final frame = await a.seal(utf8.encode('old connection'));
    await expectLater(hostB.open(frame), throwsA(isA<RemoteCryptoError>()));
  });

  test('frames that are not data frames are refused', () async {
    final (_, hostChannel) = await _pair(device, host);
    await expectLater(hostChannel.open(Uint8List.fromList([3, 0, 0])), throwsA(isA<RemoteCryptoError>()));
    final hs = await ClientHandshake.start(device, host.publicKey);
    expect(isHandshakeInit(hs.init), isTrue);
    expect(isHandshakeAccept(hs.init), isFalse);
  });

  test('fingerprints are short, stable and compared loosely', () {
    final fp = keyFingerprint(host.publicKey);
    expect(fp, matches(RegExp(r'^[0-9A-F]{4}(-[0-9A-F]{4}){3}$')));
    expect(keyFingerprint(host.publicKey), fp);
    expect(sameFingerprint(fp.toLowerCase().replaceAll('-', ' '), fp), isTrue);
    expect(sameFingerprint(keyFingerprint(device.publicKey), fp), isFalse);
    expect(sameFingerprint('', ''), isFalse);
  });

  group('protocol', () {
    test('pairing payloads parse from a QR link or a typed code', () {
      final uri = const PairingPayload(
        code: 'ABCD-EFGH',
        hostId: 'h1',
        fingerprint: '1A2B-3C4D',
        hostName: 'Mac',
      ).toUri();
      final p = PairingPayload.parse(uri)!;
      expect((p.code, p.hostId, p.fingerprint, p.hostName), ('ABCD-EFGH', 'h1', '1A2B-3C4D', 'Mac'));
      expect(PairingPayload.parse(' abcd efgh ')!.code, 'abcd efgh');
      expect(PairingPayload.parse('ABCD-EFG1'), isNull, reason: '1 is not in the alphabet');
      expect(PairingPayload.parse('everyai://pair?c=nope'), isNull);
      expect(PairingPayload.parse('https://example.com'), isNull);
      expect(normalizeCode('abcd-efgh'), 'ABCDEFGH');
      expect(displayCode('abcdefgh'), 'ABCD-EFGH');
    });

    test('tunnel messages round-trip and junk is ignored', () {
      final m = {'t': Tunnel.act, 'id': 1, 's': 'session-1', 'kind': MirrorAction.stop};
      expect(Tunnel.decode(Tunnel.encode(m)), m);
      expect(Tunnel.decode(utf8.encode('not json')), isNull);
      expect(Tunnel.decode(utf8.encode('{"id":1}')), isNull);
    });
  });
}
