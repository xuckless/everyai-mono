import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket/web_socket.dart';

import '../domain/remote_crypto.dart';
import '../domain/remote_protocol.dart';

/// Opens a relay socket with its `rh_`/`rd_` token (see `relay_socket.dart`).
typedef RelayConnector = Future<WebSocket> Function(Uri url, String token);

enum RemoteLinkStatus {
  /// Reaching the relay, or the encrypted handshake is running.
  connecting,

  /// The relay is up but the host isn't connected to it.
  hostOffline,

  /// Requests can go through.
  ready,

  /// The device was unpaired (or the host removed).
  revoked,

  /// The host's keys don't match this pairing; pair again.
  keyMismatch;

  String get label => switch (this) {
    connecting => 'Connecting',
    hostOffline => 'Host offline',
    ready => 'Connected',
    revoked => 'Unpaired',
    keyMismatch => 'Keys changed: pair again',
  };
}

/// The host can't be reached right now (offline, unpaired, or the link dropped).
final class RemoteUnavailable implements Exception {
  const RemoteUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The host got the action but turned it down; [message] says why.
final class RemoteRefused implements Exception {
  const RemoteRefused(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A device's encrypted link to one paired host through the relay.
///
/// It keeps the relay socket up (reconnecting with backoff), runs the
/// handshake whenever the host comes online, and carries tunnel messages
/// (see [Tunnel]): pushes arrive on [messages], actions go with [call].
final class RemoteClient {
  RemoteClient({
    required this.hostId,
    required List<int> hostPublicKey,
    required this.identity,
    required this.deviceToken,
    required this.relayUrl,
    required RelayConnector connect,
    this.readyTimeout = const Duration(seconds: 20),
    this.requestTimeout = const Duration(minutes: 2),
    this.handshakeRetry = const Duration(seconds: 4),
  }) : _hostKey = Uint8List.fromList(hostPublicKey),
       _connector = connect;

  final String hostId;
  final RemoteIdentity identity;
  final String deviceToken;

  /// `wss://…/v1/remote/client/<host id>`.
  final Uri relayUrl;
  final Uint8List _hostKey;
  final RelayConnector _connector;
  final Duration readyTimeout;
  final Duration requestTimeout;

  /// How long to wait for the host's accept before sending the handshake
  /// again (doubling, up to 30 s): an init the host never saw is not lost for good.
  final Duration handshakeRetry;

  WebSocket? _ws;

  /// Puts the host's long messages back together.
  final _incoming = TunnelAssembler();

  /// Handshakes sent on this socket and not yet answered, newest last. The
  /// host answers each init it gets, so an accept may be for an older one.
  final _handshakes = <ClientHandshake>[];

  /// Some sent handshakes were dropped from [_handshakes], so an accept that
  /// matches none of them may be for one of those (not a key mismatch).
  bool _forgotSome = false;
  Timer? _handshakeTimer;
  int _handshakeTries = 0;
  static const _maxHandshakes = 8;
  SecureChannel? _secure;
  var _ready = Completer<void>();
  final _pending = <int, Completer<void>>{};
  final _messages = StreamController<Map<String, Object?>>.broadcast();
  int _nextId = 1;
  bool _closed = false;
  bool _started = false;
  int _retries = 0;
  Timer? _retry;

  RemoteLinkStatus _status = RemoteLinkStatus.connecting;
  final _statusController = StreamController<RemoteLinkStatus>.broadcast();

  RemoteLinkStatus get status => _status;
  Stream<RemoteLinkStatus> get statusChanges => _statusController.stream;

  void _setStatus(RemoteLinkStatus s) {
    if (_status == s) return;
    _status = s;
    // Callers waiting for the link fail at once when it can't come back by itself.
    if ((s == RemoteLinkStatus.revoked || s == RemoteLinkStatus.keyMismatch) && !_ready.isCompleted) {
      _ready.completeError(RemoteUnavailable(_unusable(s)));
      _ready.future.ignore();
    }
    if (!_statusController.isClosed) _statusController.add(s);
  }

  /// Connects (once); later calls do nothing.
  void start() {
    if (_started) return;
    _started = true;
    unawaited(_connect());
  }

  Future<void> _connect() async {
    if (_closed) return;
    _retry = null;
    _setStatus(RemoteLinkStatus.connecting);
    final WebSocket ws;
    try {
      ws = await _connector(relayUrl, deviceToken);
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
            unawaited(_frame(data));
          case CloseReceived(:final code):
            _relayClosed(ws, code);
        }
      },
      onError: (_) => _relayClosed(ws, null),
      onDone: () => _relayClosed(ws, null),
    );
  }

  void _relayClosed(WebSocket ws, int? code) {
    if (_ws != ws) return;
    _ws = null;
    _forgetHandshakes();
    _dropChannel(const RemoteUnavailable('The connection to the host dropped.'));
    // 4003: the device was revoked; 401/403 before the upgrade arrive as errors.
    if (code == 4003) {
      _setStatus(RemoteLinkStatus.revoked);
      return;
    }
    if (_status != RemoteLinkStatus.revoked && _status != RemoteLinkStatus.keyMismatch) _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_closed || _retry != null) return;
    _setStatus(RemoteLinkStatus.connecting);
    final delay = Duration(milliseconds: 500 * (1 << _retries.clamp(0, 5)));
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
        if (n['host_online'] == true) {
          unawaited(_startHandshake());
        } else {
          _setStatus(RemoteLinkStatus.hostOffline);
        }
      case 'host_online':
        unawaited(_startHandshake());
      case 'host_offline':
        _forgetHandshakes();
        _dropChannel(const RemoteUnavailable('The host went offline.'));
        _setStatus(RemoteLinkStatus.hostOffline);
      case 'closed':
        _forgetHandshakes();
        _dropChannel(const RemoteUnavailable('The host closed the connection.'));
        _setStatus(RemoteLinkStatus.hostOffline);
      case 'revoked':
        _forgetHandshakes();
        _dropChannel(const RemoteUnavailable('This device was unpaired.'));
        _setStatus(RemoteLinkStatus.revoked);
    }
  }

  /// Sends a fresh handshake init. Earlier ones stay open: the host answers
  /// each, and only the newest one's accept makes the link ready.
  Future<void> _startHandshake() async {
    _dropChannel(const RemoteUnavailable('The host reconnected.'));
    _setStatus(RemoteLinkStatus.connecting);
    final ws = _ws;
    if (ws == null || _closed) return;
    final hs = await ClientHandshake.start(identity, _hostKey);
    if (_ws != ws || _closed || _secure != null) return;
    _handshakes.add(hs);
    if (_handshakes.length > _maxHandshakes) {
      _handshakes.removeAt(0);
      _forgotSome = true;
    }
    ws.sendBytes(hs.init);
    _handshakeTimer?.cancel();
    final wait = handshakeRetry * (1 << _handshakeTries.clamp(0, 3));
    _handshakeTries++;
    _handshakeTimer = Timer(wait > const Duration(seconds: 30) ? const Duration(seconds: 30) : wait, () {
      if (_ws == ws && _secure == null && _status == RemoteLinkStatus.connecting) unawaited(_startHandshake());
    });
  }

  void _forgetHandshakes() {
    _handshakes.clear();
    _forgotSome = false;
    _handshakeTries = 0;
    _handshakeTimer?.cancel();
    _handshakeTimer = null;
  }

  /// The host's accept: ready when it answers the newest init; an answer to
  /// an older one is passed over (the newer answer follows). Keys only
  /// mismatch when it answers none of the inits this socket sent.
  Future<void> _accept(Uint8List data) async {
    final sent = [..._handshakes];
    if (sent.isEmpty) return;
    SecureChannel? channel;
    var matched = -1;
    for (var i = sent.length - 1; i >= 0 && channel == null; i--) {
      try {
        channel = await sent[i].finish(data);
        matched = i;
      } on RemoteCryptoError {
        continue;
      }
    }
    if (channel == null) {
      // Answers to forgotten inits can't be told from a key change.
      if (_forgotSome || !_handshakes.contains(sent.last)) return;
      _forgetHandshakes();
      _setStatus(RemoteLinkStatus.keyMismatch);
      await _ws?.close().catchError((Object _) {});
      return;
    }
    final hs = sent[matched];
    final at = _handshakes.indexOf(hs);
    if (at < 0) return;
    if (at < _handshakes.length - 1) {
      // A newer init is out: the host now uses its keys.
      _handshakes.removeRange(0, at + 1);
      _forgotSome = true;
      return;
    }
    _forgetHandshakes();
    _secure = channel;
    _setStatus(RemoteLinkStatus.ready);
    if (!_ready.isCompleted) _ready.complete();
  }

  Future<void> _frame(Uint8List data) async {
    if (isHandshakeAccept(data)) return _accept(data);
    final secure = _secure;
    if (secure == null) return;
    try {
      await secure.open(data, (clear) {
        if (_incoming.add(clear) case final m?) _dispatch(m);
      });
    } on RemoteCryptoError {
      // Tampered or replayed: dropped.
    }
  }

  void _dispatch(Map<String, Object?> m) {
    if (m['t'] == Tunnel.done) {
      final done = _pending.remove(m['id']);
      if (m['error'] case final String error) {
        done?.completeError(RemoteRefused(error));
      } else {
        done?.complete();
      }
      return;
    }
    if (!_messages.isClosed) _messages.add(m);
  }

  /// Ends the encrypted channel: actions in flight fail with [error].
  void _dropChannel(RemoteUnavailable error) {
    _secure = null;
    _incoming.reset();
    if (_ready.isCompleted) _ready = Completer<void>();
    for (final c in _pending.values) {
      c.completeError(error);
    }
    _pending.clear();
  }

  Future<void> _whenReady() async {
    if (_closed) throw const RemoteUnavailable('The remote link is closed.');
    start();
    if (_secure != null) return;
    if (_status case RemoteLinkStatus.revoked || RemoteLinkStatus.keyMismatch) {
      throw RemoteUnavailable(_unusable(_status));
    }
    try {
      await _ready.future.timeout(readyTimeout);
    } on TimeoutException {
      throw RemoteUnavailable(
        _status == RemoteLinkStatus.hostOffline
            ? 'The host is offline. Open EveryAI on it and turn on hosting.'
            : "Couldn't reach the host.",
      );
    }
  }

  static String _unusable(RemoteLinkStatus s) => s == RemoteLinkStatus.revoked
      ? 'This device was unpaired from the host.'
      : "The host's keys changed. Pair this device again.";

  void _send(Map<String, Object?> message) {
    final secure = _secure;
    final ws = _ws;
    if (secure == null || ws == null) throw const RemoteUnavailable('The host is not connected.');
    // Back to back, so a long message's parts are never split up by another.
    for (final part in Tunnel.split(message)) {
      unawaited(secure.seal(part, ws.sendBytes).then((_) {}, onError: (_) {}));
    }
  }

  /// What the host pushes (session lists, mirrored events and state). After
  /// the link comes back ([statusChanges] is ready again) ask again: the host
  /// forgot what this device followed.
  Stream<Map<String, Object?>> get messages => _messages.stream;

  /// Sends [message] once the link is up.
  Future<void> send(Map<String, Object?> message) async {
    await _whenReady();
    _send(message);
  }

  /// Sends [message] (an `act`) with a fresh id and waits for the host's
  /// `done`; a [RemoteRefused] when the host turned it down.
  Future<void> call(Map<String, Object?> message) async {
    await _whenReady();
    final id = _nextId++;
    final done = _pending[id] = Completer<void>();
    _send({...message, 'id': id});
    try {
      return await done.future.timeout(requestTimeout);
    } on TimeoutException {
      _pending.remove(id);
      throw const RemoteUnavailable("The host didn't answer in time.");
    }
  }

  Future<void> close() async {
    _closed = true;
    _retry?.cancel();
    _forgetHandshakes();
    _dropChannel(const RemoteUnavailable('The remote link is closed.'));
    final ws = _ws;
    _ws = null;
    await ws?.close().catchError((Object _) {});
    await _statusController.close();
    await _messages.close();
  }
}
