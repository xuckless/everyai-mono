import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket/web_socket.dart';

import '../domain/remote_crypto.dart';
import 'host_bridge.dart';
import 'relay_client.dart' show RelayConnector;

/// A device asking to pair with this host (from a `pair_request` notice).
@immutable
final class PairRequest {
  const PairRequest({
    required this.pairingId,
    required this.deviceId,
    required this.deviceName,
    required this.publicKey,
    required this.decideBy,
  });

  final String pairingId;
  final String deviceId;
  final String deviceName;

  /// Base64 X25519 key the device sent.
  final String publicKey;
  final DateTime decideBy;

  /// What the device shows too, to compare by eye.
  String get fingerprint {
    try {
      return keyFingerprint(decodePublicKey(publicKey));
    } on RemoteCryptoError {
      return 'invalid key';
    }
  }

  /// From a `pair_request` notice or a `hello`'s `pending_pairings` entry.
  static PairRequest? fromJson(Map<String, Object?> j) {
    final device = j['device'];
    final id = j['pairing_id'];
    final deviceId = device is Map ? device['id'] : j['device_id'];
    final name = device is Map ? device['name'] : j['device_name'];
    final key = device is Map ? device['public_key'] : j['public_key'];
    final by = j['decide_by'];
    if (id is! String || deviceId is! String || key is! String || by is! num) return null;
    return PairRequest(
      pairingId: id,
      deviceId: deviceId,
      deviceName: name is String ? name : 'A device',
      publicKey: key,
      decideBy: DateTime.fromMillisecondsSinceEpoch(by.toInt() * 1000),
    );
  }
}

/// A paired device connected through the relay right now.
typedef ConnectedDevice = ({int channel, String deviceId, String deviceName});

@immutable
final class HostLinkState {
  const HostLinkState({
    this.connected = false,
    this.clients = const [],
    this.pending = const [],
    this.revoked = false,
    this.replaced = false,
  });

  /// The relay socket is up (devices can reach this host).
  final bool connected;
  final List<ConnectedDevice> clients;
  final List<PairRequest> pending;

  /// The backend removed this host; hosting must be set up again.
  final bool revoked;

  /// Another copy of this host connected (it took over).
  final bool replaced;

  HostLinkState copyWith({
    bool? connected,
    List<ConnectedDevice>? clients,
    List<PairRequest>? pending,
    bool? revoked,
    bool? replaced,
  }) => HostLinkState(
    connected: connected ?? this.connected,
    clients: clients ?? this.clients,
    pending: pending ?? this.pending,
    revoked: revoked ?? this.revoked,
    replaced: replaced ?? this.replaced,
  );
}

/// This desktop's socket to the relay (`WS /v1/remote/host`): it keeps it up,
/// turns notices into [HostLinkState], and hands device frames to a
/// [HostBridge]. Host frames carry a 4-byte big-endian channel prefix.
final class RemoteHostLink {
  RemoteHostLink({
    required this.url,
    required this.token,
    required RelayConnector connect,
    required HostBridge Function(void Function(int channel, Uint8List payload) send) bridge,
    required this._approvedKey,
  }) : _connector = connect {
    _bridge = bridge(_sendTo);
  }

  /// `wss://…/v1/remote/host`.
  final Uri url;
  final String token;
  final RelayConnector _connector;
  final String? Function(String deviceId) _approvedKey;
  late final HostBridge _bridge;

  WebSocket? _ws;
  bool _closed = false;
  bool _started = false;
  int _retries = 0;
  Timer? _retry;

  HostLinkState _state = const HostLinkState();
  final _changes = StreamController<HostLinkState>.broadcast();

  HostLinkState get state => _state;
  Stream<HostLinkState> get changes => _changes.stream;

  void _set(HostLinkState s) {
    _state = s;
    if (!_changes.isClosed) _changes.add(s);
  }

  void start() {
    if (_started) return;
    _started = true;
    unawaited(_connect());
  }

  /// Drops [pairingId] from the pending list (after approving or denying it).
  void settled(String pairingId) =>
      _set(_state.copyWith(pending: [..._state.pending.where((p) => p.pairingId != pairingId)]));

  /// Disconnects the device on [channel].
  void closeChannel(int channel) {
    _bridge.closeChannel(channel);
    _ws?.sendText(jsonEncode({'type': 'close_channel', 'channel': channel}));
  }

  Future<void> _connect() async {
    if (_closed) return;
    _retry = null;
    final WebSocket ws;
    try {
      ws = await _connector(url, token);
    } on Object {
      _scheduleReconnect();
      return;
    }
    if (_closed) {
      unawaited(ws.close().catchError((Object _) {}));
      return;
    }
    _ws = ws;
    ws.events.listen(
      (event) {
        switch (event) {
          case TextDataReceived(:final text):
            _notice(text);
          case BinaryDataReceived(:final data):
            if (data.length < 4) return;
            final channel = ByteData.sublistView(data, 0, 4).getUint32(0);
            unawaited(_bridge.receive(channel, Uint8List.sublistView(data, 4)));
          case CloseReceived():
            _dropped(ws);
        }
      },
      onError: (_) => _dropped(ws),
      onDone: () => _dropped(ws),
    );
  }

  void _dropped(WebSocket ws) {
    if (_ws != ws) return;
    _ws = null;
    _bridge.closeAll();
    _set(_state.copyWith(connected: false, clients: const []));
    if (!_state.revoked && !_state.replaced) _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_closed || _retry != null) return;
    final delay = Duration(milliseconds: 500 * (1 << _retries.clamp(0, 6)));
    _retries++;
    _retry = Timer(delay, () => unawaited(_connect()));
  }

  void _notice(String text) {
    final Object? n;
    try {
      n = jsonDecode(text);
    } on FormatException {
      return;
    }
    if (n is! Map<String, Object?>) return;
    switch (n['type']) {
      case 'hello':
        _retries = 0;
        _bridge.closeAll();
        final clients = <ConnectedDevice>[];
        for (final c in n['clients'] as List<Object?>? ?? const []) {
          if (c is Map<String, Object?>) clients.addAll(_open(c));
        }
        _set(
          _state.copyWith(
            connected: true,
            clients: clients,
            pending: [
              for (final p in n['pending_pairings'] as List<Object?>? ?? const [])
                if (p is Map<String, Object?>) ?PairRequest.fromJson(p),
            ],
          ),
        );
      case 'client_open':
        final opened = _open(n);
        if (opened.isNotEmpty) {
          _set(
            _state.copyWith(clients: [..._state.clients.where((c) => c.channel != opened.first.channel), ...opened]),
          );
        }
      case 'client_close':
        final channel = (n['channel'] as num?)?.toInt();
        if (channel == null) return;
        _bridge.closeChannel(channel);
        _set(_state.copyWith(clients: [..._state.clients.where((c) => c.channel != channel)]));
      case 'pair_request':
        if (PairRequest.fromJson(n) case final p?) {
          _set(_state.copyWith(pending: [..._state.pending.where((x) => x.pairingId != p.pairingId), p]));
        }
      case 'replaced':
        _set(_state.copyWith(replaced: true));
      case 'revoked':
        _set(_state.copyWith(revoked: true));
    }
  }

  /// Opens a bridge channel for a `client_open`/`hello` entry, if its key is
  /// the one this host approved (the relay can't slip in another device).
  List<ConnectedDevice> _open(Map<String, Object?> c) {
    final channel = (c['channel'] as num?)?.toInt();
    final deviceId = c['device_id'];
    final key = c['public_key'];
    if (channel == null || deviceId is! String || key is! String) return const [];
    final approved = _approvedKey(deviceId);
    if (approved == null || approved != key) {
      _ws?.sendText(jsonEncode({'type': 'close_channel', 'channel': channel}));
      return const [];
    }
    try {
      _bridge.openChannel(channel, deviceId: deviceId, publicKey: decodePublicKey(key));
    } on RemoteCryptoError {
      return const [];
    }
    return [(channel: channel, deviceId: deviceId, deviceName: c['device_name'] as String? ?? 'A device')];
  }

  void _sendTo(int channel, Uint8List payload) {
    final ws = _ws;
    if (ws == null) return;
    final frame = Uint8List(4 + payload.length);
    ByteData.sublistView(frame, 0, 4).setUint32(0, channel);
    frame.setRange(4, frame.length, payload);
    ws.sendBytes(frame);
  }

  Future<void> close() async {
    _closed = true;
    _retry?.cancel();
    _bridge.closeAll();
    final ws = _ws;
    _ws = null;
    await ws?.close().catchError((Object _) {});
    await _changes.close();
  }
}
