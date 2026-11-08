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

/// A webhook delivery the relay passed on (a `webhook` notice; see backend-exp `hooks.zig`). The body comes from an
/// outside sender: it is untrusted data, and the server could read it (this notice is not end-to-end encrypted).
@immutable
final class WebhookDelivery {
  const WebhookDelivery({
    required this.id,
    required this.hookId,
    required this.hookName,
    required this.headers,
    required this.body,
    required this.receivedAt,
  });

  final String id;
  final String hookId;
  final String hookName;

  /// The few headers the relay passes on, lower-case (`content-type`, `x-github-event`, …).
  final Map<String, String> headers;
  final Uint8List body;
  final DateTime receivedAt;

  /// The event name the sender gave: GitHub's `X-GitHub-Event`, else `X-EveryAI-Event`.
  String? get event => headers['x-github-event'] ?? headers['x-everyai-event'];

  static WebhookDelivery? fromJson(Map<String, Object?> j) {
    final id = j['delivery_id'];
    final hook = j['hook_id'];
    final b64 = j['body_b64'];
    if (id is! String || id.isEmpty || hook is! String || b64 is! String) return null;
    final Uint8List body;
    try {
      body = base64Decode(b64);
    } on FormatException {
      return null;
    }
    final headers = j['headers'];
    return WebhookDelivery(
      id: id,
      hookId: hook,
      hookName: j['hook_name'] as String? ?? '',
      headers: {
        if (headers is Map<String, Object?>)
          for (final e in headers.entries)
            if (e.value is String) e.key.toLowerCase(): e.value! as String,
      },
      body: body,
      receivedAt: DateTime.fromMillisecondsSinceEpoch(((j['received_at'] as num?) ?? 0).toInt() * 1000),
    );
  }
}

/// A paired device connected through the relay right now.
typedef ConnectedDevice = ({int channel, String deviceId, String deviceName});

/// Where this host's relay socket stands:
///
/// ```text
///  connecting ──queued──► queued(position) ──hello──► online ──socket dropped──► connecting (reconnects)
///       │                                                 │
///       ├──budget──► overBudget(resetsAt) ──resetsAt──► connecting
///       └──── replaced / revoked (from any) ────► replaced | revoked   (final: no reconnect)
/// ```
enum HostLinkStatus {
  connecting,

  /// The relay is full; this host waits in line ([HostLinkState.queuePosition]).
  queued,
  online,

  /// The relay's limit for this host (or its account) is spent until
  /// [HostLinkState.budgetResetsAt]; it reconnects then by itself.
  overBudget,

  /// Another copy of this host connected (it took over).
  replaced,

  /// The backend removed this host; hosting must be set up again.
  revoked;

  bool get ended => this == replaced || this == revoked;
}

@immutable
final class HostLinkState {
  const HostLinkState({
    this.status = HostLinkStatus.connecting,
    this.clients = const [],
    this.pending = const [],
    this.queuePosition,
    this.budgetResetsAt,
  });

  final HostLinkStatus status;

  /// Set while [status] is [HostLinkStatus.queued] (1 = next).
  final int? queuePosition;

  /// Set while [status] is [HostLinkStatus.overBudget].
  final DateTime? budgetResetsAt;
  final List<ConnectedDevice> clients;
  final List<PairRequest> pending;

  /// The relay socket is up (devices can reach this host).
  bool get connected => status == HostLinkStatus.online;
  bool get revoked => status == HostLinkStatus.revoked;
  bool get replaced => status == HostLinkStatus.replaced;

  /// Moves to [next] unless the link already ended (a hello or a drop after `replaced` changes nothing).
  /// The queue place and reset time belong to their states and are dropped on leaving them.
  HostLinkState to(HostLinkStatus next, {int? queuePosition, DateTime? budgetResetsAt}) => status.ended
      ? this
      : HostLinkState(
          status: next,
          clients: clients,
          pending: pending,
          queuePosition: next == HostLinkStatus.queued ? queuePosition : null,
          budgetResetsAt: next == HostLinkStatus.overBudget ? budgetResetsAt : null,
        );

  HostLinkState copyWith({List<ConnectedDevice>? clients, List<PairRequest>? pending}) => HostLinkState(
    status: status,
    clients: clients ?? this.clients,
    pending: pending ?? this.pending,
    queuePosition: queuePosition,
    budgetResetsAt: budgetResetsAt,
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
    this.onWebhook,
  }) : _connector = connect {
    _bridge = bridge(_sendTo);
  }

  /// `wss://…/v1/remote/host`.
  final Uri url;
  final String token;
  final RelayConnector _connector;
  final String? Function(String deviceId) _approvedKey;

  /// Gets each webhook delivery; it answers with [ackWebhook] once it is handled.
  final void Function(WebhookDelivery delivery)? onWebhook;
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

  /// Tells the relay [deliveryId] was handled, so it isn't sent again on the next connect.
  void ackWebhook(String deliveryId) => _ws?.sendText(jsonEncode({'type': 'webhook_ack', 'delivery_id': deliveryId}));

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
    if (_state.status == HostLinkStatus.overBudget) {
      // Back when the limit resets (at least a minute from now).
      _set(_state.copyWith(clients: const []));
      _retry?.cancel();
      var wait = (_state.budgetResetsAt ?? DateTime.now().add(const Duration(hours: 1))).difference(DateTime.now());
      if (wait < const Duration(minutes: 1)) wait = const Duration(minutes: 1);
      _retry = Timer(wait, () {
        _retries = 0;
        _set(_state.to(HostLinkStatus.connecting));
        unawaited(_connect());
      });
      return;
    }
    _set(_state.to(HostLinkStatus.connecting).copyWith(clients: const []));
    if (!_state.status.ended) _scheduleReconnect();
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
          _state
              .to(HostLinkStatus.online)
              .copyWith(
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
      case 'webhook':
        if (WebhookDelivery.fromJson(n) case final d?) onWebhook?.call(d);
      case 'queued':
        _set(_state.to(HostLinkStatus.queued, queuePosition: (n['position'] as num?)?.toInt()));
      case 'budget':
        final at = (n['resets_at'] as num?)?.toInt();
        _set(
          _state.to(
            HostLinkStatus.overBudget,
            budgetResetsAt: at == null ? null : DateTime.fromMillisecondsSinceEpoch(at * 1000),
          ),
        );
      case 'replaced':
        _set(_state.to(HostLinkStatus.replaced));
      case 'revoked':
        _set(_state.to(HostLinkStatus.revoked));
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
