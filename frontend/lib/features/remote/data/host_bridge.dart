import 'dart:async';
import 'dart:typed_data';

import '../domain/remote_crypto.dart';
import '../domain/remote_protocol.dart';

/// Gets a device's messages (decrypted, put back together) on [channel].
typedef TunnelHandler = void Function(int channel, Map<String, Object?> message);

/// The host's side of the tunnel: one encrypted channel per connected device.
/// It runs the handshake with the key approved at pairing, opens what the
/// device sends and hands each message to [onMessage]; [send] seals the
/// answers. What the messages mean is up to the handler (`HostMirror`).
final class HostBridge {
  HostBridge({
    required this.identity,
    required this.hostId,
    required this._send,
    required this.onMessage,
    this.onChannelClosed,
  });

  final RemoteIdentity identity;
  final String hostId;
  final void Function(int channel, Uint8List payload) _send;
  final TunnelHandler onMessage;

  /// A device went away (or reconnected, which starts a new channel state).
  final void Function(int channel)? onChannelClosed;

  final _channels = <int, _Channel>{};

  /// Channels with a device connected.
  Iterable<int> get channels => _channels.keys;

  /// Channels whose handshake is done, so [send] reaches them.
  Iterable<int> get readyChannels => [
    for (final e in _channels.entries)
      if (e.value.secure != null) e.key,
  ];

  /// A device connected on [channel]; [publicKey] is the key approved at pairing.
  void openChannel(int channel, {required String deviceId, required List<int> publicKey}) {
    if (_channels.remove(channel) case final old?) _drop(channel, old);
    _channels[channel] = _Channel(deviceId, publicKey);
  }

  void closeChannel(int channel) {
    if (_channels.remove(channel) case final old?) _drop(channel, old);
  }

  /// Closes every channel (the relay dropped, or hosting stopped).
  void closeAll() {
    for (final e in [..._channels.entries]) {
      _drop(e.key, e.value);
    }
    _channels.clear();
  }

  void _drop(int channel, _Channel ch) {
    final had = ch.secure != null;
    ch.reset();
    if (had) onChannelClosed?.call(channel);
  }

  /// A frame from the device on [channel].
  Future<void> receive(int channel, Uint8List payload) async {
    final ch = _channels[channel];
    if (ch == null) return;
    if (isHandshakeInit(payload)) {
      // Inits are worked out concurrently: only the newest one is answered,
      // so the device and this side end up on the same keys.
      final seq = ++ch.handshakes;
      try {
        final (accept, secure) = await acceptHandshake(identity, ch.publicKey, payload);
        if (_channels[channel] != ch || ch.handshakes != seq) return;
        // A new handshake is a reconnected device: what it mirrored is gone.
        _drop(channel, ch);
        ch.secure = secure;
        _send(channel, accept);
      } on RemoteCryptoError {
        return;
      }
      return;
    }
    final secure = ch.secure;
    if (secure == null) return;
    try {
      await secure.open(payload, (clear) {
        final message = ch.incoming.add(clear);
        if (message != null && _channels[channel] == ch && ch.secure == secure) onMessage(channel, message);
      });
    } on RemoteCryptoError {
      // Tampered or replayed: dropped.
    }
  }

  /// Seals [message] to the device on [channel]; false when it isn't connected.
  bool send(int channel, Map<String, Object?> message) {
    final ch = _channels[channel];
    final secure = ch?.secure;
    if (secure == null) return false;
    // Back to back, so a long message's parts are never split up by another.
    for (final part in Tunnel.split(message)) {
      unawaited(
        secure
            .seal(part, (frame) {
              if (_channels[channel] == ch) _send(channel, frame);
            })
            .then((_) {}, onError: (_) {}),
      );
    }
    return true;
  }
}

final class _Channel {
  _Channel(this.deviceId, this.publicKey);
  final String deviceId;
  final List<int> publicKey;
  SecureChannel? secure;

  /// Handshake inits received, to answer only the newest.
  int handshakes = 0;

  /// Puts the device's long messages back together.
  final incoming = TunnelAssembler();

  void reset() {
    secure = null;
    incoming.reset();
  }
}
