import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';

/// End-to-end encryption between a remote host and a paired device. The
/// backend relays the frames and never sees a key.
///
/// Each side has a long-term X25519 key; the public halves are exchanged at
/// pairing (through the backend, so the host's key is also checked against
/// the fingerprint in the QR code, or by eye). Every connection then runs a
/// one-round handshake with fresh ephemeral keys:
///
/// - init (client → host): `01 | version | ephemeral_c (32)`
/// - accept (host → client): `02 | version | ephemeral_h (32) | confirm (16)`
///
/// Both sides mix four Diffie-Hellman results (static-static,
/// ephemeral-ephemeral and both crosses) through HKDF-SHA256, salted with a
/// hash of all four public keys, into one ChaCha20-Poly1305 key per
/// direction. Only the holders of both static private keys get the same keys,
/// so a relay that swaps keys only produces frames that fail to open. The
/// confirm tag is an empty message sealed with the host's key, so a client
/// learns at once when the pairing no longer matches.
///
/// Data frames: `03 | counter (8, big-endian) | ciphertext | tag (16)`. The
/// nonce is the counter (each direction has its own key, so nonces never
/// repeat) and the 9-byte header is authenticated. A receiver only accepts
/// counters above the last one it opened, which rejects replays.
const remoteProtocolVersion = 1;

const _initType = 1;
const _acceptType = 2;
const _dataType = 3;
const _keyLength = 32;
const _tagLength = 16;
const _headerLength = 9;

// 64-bit counters as two 32-bit halves: the web has no getUint64.
const _high = 0x100000000;

final _x25519 = X25519();
final _aead = Chacha20.poly1305Aead();
final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 2 * _keyLength);

/// A frame that isn't valid for the protocol, or one that fails to open.
final class RemoteCryptoError implements Exception {
  const RemoteCryptoError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A long-term X25519 key pair (one per host install, one per paired device).
final class RemoteIdentity {
  RemoteIdentity._(this.keyPair, this.publicKey, this.privateKey);

  final SimpleKeyPair keyPair;
  final Uint8List publicKey;
  final Uint8List privateKey;

  static Future<RemoteIdentity> generate() async {
    final seed = Uint8List(_keyLength);
    final random = Random.secure();
    for (var i = 0; i < seed.length; i++) {
      seed[i] = random.nextInt(256);
    }
    return fromPrivateKey(seed);
  }

  static Future<RemoteIdentity> fromPrivateKey(List<int> privateKey) async {
    if (privateKey.length != _keyLength) throw const RemoteCryptoError('A remote key must be 32 bytes.');
    final pair = await _x25519.newKeyPairFromSeed(privateKey);
    final public = await pair.extractPublicKey();
    return RemoteIdentity._(pair, Uint8List.fromList(public.bytes), Uint8List.fromList(privateKey));
  }

  /// From [privateKeyBase64] as [privateKeyBase64] stored it.
  static Future<RemoteIdentity> restore(String privateKeyBase64) => fromPrivateKey(base64Decode(privateKeyBase64));

  String get publicKeyBase64 => base64Encode(publicKey);
  String get privateKeyBase64 => base64Encode(privateKey);
}

/// A public key as the backend carries it (standard base64 of 32 bytes).
Uint8List decodePublicKey(String base64Key) {
  final Uint8List bytes;
  try {
    bytes = base64Decode(base64Key.trim());
  } on FormatException {
    throw const RemoteCryptoError('The public key is not base64.');
  }
  if (bytes.length != _keyLength) throw const RemoteCryptoError('The public key is not an X25519 key.');
  return bytes;
}

/// A short form of [publicKey] to compare by eye or carry in a QR code:
/// the first 8 bytes of its SHA-256 as four groups of hex (`1A2B-3C4D-…`).
String keyFingerprint(List<int> publicKey) {
  final digest = hash.sha256.convert(publicKey).bytes.take(8);
  final hex = digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
  return [for (var i = 0; i < hex.length; i += 4) hex.substring(i, i + 4)].join('-');
}

/// Whether [a] and [b] are the same fingerprint, ignoring case, dashes and spaces.
bool sameFingerprint(String a, String b) {
  String norm(String s) => s.toUpperCase().replaceAll(RegExp('[^0-9A-F]'), '');
  return norm(a).isNotEmpty && norm(a) == norm(b);
}

/// One connection's keys: seals what this side sends and opens what it receives.
final class SecureChannel {
  SecureChannel._(this._sendKey, this._receiveKey, {required int sendFrom}) : _sent = sendFrom;

  final SecretKey _sendKey;
  final SecretKey _receiveKey;
  int _sent;
  int _received = -1;

  // Sealing and opening are async; chaining keeps frames in counter order.
  Future<void> _sendTail = Future.value();
  Future<void> _receiveTail = Future.value();

  /// [plaintext] as a data frame. Frames complete in the order they were
  /// asked for; [deliver] gets each one in that order too (send it there).
  Future<Uint8List> seal(List<int> plaintext, [void Function(Uint8List frame)? deliver]) {
    final counter = _sent++;
    final frame = _sendTail.then((_) async {
      final header = _header(_dataType, counter);
      final box = await _aead.encrypt(plaintext, secretKey: _sendKey, nonce: _nonce(counter), aad: header);
      final frame = Uint8List.fromList([...header, ...box.cipherText, ...box.mac.bytes]);
      deliver?.call(frame);
      return frame;
    });
    _sendTail = frame.then((_) {}, onError: (Object _) {});
    return frame;
  }

  /// The plaintext of a data [frame]. Throws [RemoteCryptoError] for a
  /// tampered, replayed or malformed frame. Results complete in call order;
  /// [deliver] gets each plaintext in that order (handle it there).
  Future<Uint8List> open(Uint8List frame, [void Function(Uint8List plaintext)? deliver]) {
    final clear = _receiveTail.then((_) async {
      final plaintext = await _open(frame);
      deliver?.call(plaintext);
      return plaintext;
    });
    _receiveTail = clear.then((_) {}, onError: (Object _) {});
    return clear;
  }

  Future<Uint8List> _open(Uint8List frame) async {
    if (frame.length < _headerLength + _tagLength || frame[0] != _dataType) {
      throw const RemoteCryptoError('Not a data frame.');
    }
    final view = ByteData.sublistView(frame, 1, _headerLength);
    final counter = view.getUint32(0) * _high + view.getUint32(4);
    if (counter <= _received) throw const RemoteCryptoError('A replayed frame.');
    final plaintext = await _openBox(
      _receiveKey,
      counter,
      frame.sublist(0, _headerLength),
      frame.sublist(_headerLength, frame.length - _tagLength),
      frame.sublist(frame.length - _tagLength),
    );
    _received = counter;
    return plaintext;
  }
}

Future<Uint8List> _openBox(SecretKey key, int counter, List<int> aad, List<int> cipherText, List<int> tag) async {
  try {
    final clear = await _aead.decrypt(
      SecretBox(cipherText, nonce: _nonce(counter), mac: Mac(tag)),
      secretKey: key,
      aad: aad,
    );
    return Uint8List.fromList(clear);
  } on SecretBoxAuthenticationError {
    throw const RemoteCryptoError('A frame failed to open: wrong keys or tampered.');
  }
}

Uint8List _header(int type, int counter) {
  final header = ByteData(_headerLength)
    ..setUint8(0, type)
    ..setUint32(1, counter ~/ _high)
    ..setUint32(5, counter % _high);
  return header.buffer.asUint8List();
}

List<int> _nonce(int counter) {
  final nonce = ByteData(12)
    ..setUint32(4, counter ~/ _high)
    ..setUint32(8, counter % _high);
  return nonce.buffer.asUint8List();
}

/// Whether [frame] is a handshake init (a client asks for a fresh channel).
bool isHandshakeInit(Uint8List frame) => frame.isNotEmpty && frame[0] == _initType;

/// Whether [frame] is a handshake accept.
bool isHandshakeAccept(Uint8List frame) => frame.isNotEmpty && frame[0] == _acceptType;

/// The client's half of the handshake: send [init], then [finish] with the host's accept.
final class ClientHandshake {
  ClientHandshake._(this._identity, this._hostKey, this._ephemeral, this._ephemeralPublic);

  final RemoteIdentity _identity;
  final Uint8List _hostKey;
  final SimpleKeyPair _ephemeral;
  final Uint8List _ephemeralPublic;

  static Future<ClientHandshake> start(RemoteIdentity identity, List<int> hostPublicKey) async {
    final ephemeral = await _x25519.newKeyPair();
    final public = Uint8List.fromList((await ephemeral.extractPublicKey()).bytes);
    return ClientHandshake._(identity, Uint8List.fromList(hostPublicKey), ephemeral, public);
  }

  Uint8List get init => Uint8List.fromList([_initType, remoteProtocolVersion, ..._ephemeralPublic]);

  Future<SecureChannel> finish(Uint8List accept) async {
    if (accept.length != 2 + _keyLength + _tagLength || accept[0] != _acceptType) {
      throw const RemoteCryptoError('Not a handshake accept.');
    }
    if (accept[1] != remoteProtocolVersion) throw const RemoteCryptoError('The host speaks another protocol version.');
    final hostEphemeral = accept.sublist(2, 2 + _keyLength);
    final keys = await _derive(
      staticStatic: await _dh(_identity.keyPair, _hostKey),
      ephemeralEphemeral: await _dh(_ephemeral, hostEphemeral),
      clientStaticHostEphemeral: await _dh(_identity.keyPair, hostEphemeral),
      clientEphemeralHostStatic: await _dh(_ephemeral, _hostKey),
      clientStatic: _identity.publicKey,
      hostStatic: _hostKey,
      clientEphemeral: _ephemeralPublic,
      hostEphemeral: hostEphemeral,
    );
    try {
      await _openBox(keys.hostToClient, 0, _confirmAad, const [], accept.sublist(2 + _keyLength));
    } on RemoteCryptoError {
      throw const RemoteCryptoError("The host's keys don't match this pairing. Pair this device again.");
    }
    return SecureChannel._(keys.clientToHost, keys.hostToClient, sendFrom: 0).._received = 0;
  }
}

/// The host's answer to a client's [init] frame: the accept frame to send
/// back and the channel for the connection.
Future<(Uint8List accept, SecureChannel channel)> acceptHandshake(
  RemoteIdentity identity,
  List<int> clientPublicKey,
  Uint8List init,
) async {
  if (init.length != 2 + _keyLength || init[0] != _initType) throw const RemoteCryptoError('Not a handshake init.');
  if (init[1] != remoteProtocolVersion) throw const RemoteCryptoError('The client speaks another protocol version.');
  final clientEphemeral = init.sublist(2);
  final ephemeral = await _x25519.newKeyPair();
  final ephemeralPublic = Uint8List.fromList((await ephemeral.extractPublicKey()).bytes);
  final keys = await _derive(
    staticStatic: await _dh(identity.keyPair, clientPublicKey),
    ephemeralEphemeral: await _dh(ephemeral, clientEphemeral),
    clientStaticHostEphemeral: await _dh(ephemeral, clientPublicKey),
    clientEphemeralHostStatic: await _dh(identity.keyPair, clientEphemeral),
    clientStatic: clientPublicKey,
    hostStatic: identity.publicKey,
    clientEphemeral: clientEphemeral,
    hostEphemeral: ephemeralPublic,
  );
  final confirm = await _aead.encrypt(const [], secretKey: keys.hostToClient, nonce: _nonce(0), aad: _confirmAad);
  final accept = Uint8List.fromList([_acceptType, remoteProtocolVersion, ...ephemeralPublic, ...confirm.mac.bytes]);
  // The confirm tag used counter 0 of the host's direction.
  return (accept, SecureChannel._(keys.hostToClient, keys.clientToHost, sendFrom: 1));
}

final _confirmAad = utf8.encode('everyai-remote-confirm');

Future<List<int>> _dh(SimpleKeyPair mine, List<int> theirs) async {
  final shared = await _x25519.sharedSecretKey(
    keyPair: mine,
    remotePublicKey: SimplePublicKey(theirs, type: KeyPairType.x25519),
  );
  return shared.extractBytes();
}

Future<({SecretKey clientToHost, SecretKey hostToClient})> _derive({
  required List<int> staticStatic,
  required List<int> ephemeralEphemeral,
  required List<int> clientStaticHostEphemeral,
  required List<int> clientEphemeralHostStatic,
  required List<int> clientStatic,
  required List<int> hostStatic,
  required List<int> clientEphemeral,
  required List<int> hostEphemeral,
}) async {
  final salt = hash.sha256.convert([
    ...utf8.encode('everyai-remote-v$remoteProtocolVersion'),
    ...clientStatic,
    ...hostStatic,
    ...clientEphemeral,
    ...hostEphemeral,
  ]).bytes;
  final out = await _hkdf.deriveKey(
    secretKey: SecretKey([
      ...staticStatic,
      ...ephemeralEphemeral,
      ...clientStaticHostEphemeral,
      ...clientEphemeralHostStatic,
    ]),
    nonce: salt,
    info: utf8.encode('everyai-remote keys'),
  );
  final bytes = await out.extractBytes();
  return (clientToHost: SecretKey(bytes.sublist(0, _keyLength)), hostToClient: SecretKey(bytes.sublist(_keyLength)));
}
