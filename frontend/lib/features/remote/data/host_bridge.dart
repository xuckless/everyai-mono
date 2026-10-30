import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:web_socket/web_socket.dart';

import '../domain/remote_crypto.dart';
import '../domain/remote_protocol.dart';

/// Opens a WebSocket (the agent-server's event socket, or the relay).
typedef SocketConnector = Future<WebSocket> Function(Uri url);

/// Where the local agent-server listens and its session key (as `AgentServerLocator`).
typedef ServerLocator = Future<(Uri baseUrl, String sessionApiKey)> Function();

/// A project the host offers to its devices.
typedef HostProject = ({String name, String path});

/// The host's side of the tunnel: one encrypted channel per connected device,
/// each bridged to the local agent-server's REST API and event sockets.
///
/// The bridge never forwards the server's address or key; it adds the key to
/// each call and replaces the auth frame a device's socket sends. Only the
/// conversation API and event sockets are reachable, and a conversation can
/// only start in a folder [allowedDir] accepts.
final class HostBridge {
  HostBridge({
    required this.identity,
    required this.hostId,
    required this._locate,
    required this._send,
    http.Client? client,
    SocketConnector? connectSocket,
    List<HostProject> Function()? projects,
    bool Function(String dir)? allowedDir,
  }) : _http = client ?? http.Client(),
       _connectSocket = connectSocket ?? WebSocket.connect,
       _projects = projects ?? (() => const []),
       _allowedDir = allowedDir ?? ((_) => true);

  final RemoteIdentity identity;
  final String hostId;
  final ServerLocator _locate;
  final void Function(int channel, Uint8List payload) _send;
  final http.Client _http;
  final SocketConnector _connectSocket;
  final List<HostProject> Function() _projects;
  final bool Function(String dir) _allowedDir;

  final _channels = <int, _Channel>{};

  /// Channels with a device connected.
  Iterable<int> get channels => _channels.keys;

  /// A device connected on [channel]; [publicKey] is the key approved at pairing.
  void openChannel(int channel, {required String deviceId, required List<int> publicKey}) {
    _channels.remove(channel)?.reset();
    _channels[channel] = _Channel(deviceId, publicKey);
  }

  void closeChannel(int channel) => _channels.remove(channel)?.reset();

  /// Closes every channel (the relay dropped, or hosting stopped).
  void closeAll() {
    for (final c in _channels.values) {
      c.reset();
    }
    _channels.clear();
  }

  /// A frame from the device on [channel].
  Future<void> receive(int channel, Uint8List payload) async {
    final ch = _channels[channel];
    if (ch == null) return;
    if (isHandshakeInit(payload)) {
      try {
        final (accept, secure) = await acceptHandshake(identity, ch.publicKey, payload);
        if (_channels[channel] != ch) return;
        // A new handshake is a reconnected device: its old sockets are gone.
        ch.reset();
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
        final message = Tunnel.decode(clear);
        if (message != null) _handle(channel, ch, message);
      });
    } on RemoteCryptoError {
      // Tampered or replayed: dropped.
    }
  }

  void _reply(int channel, _Channel ch, Map<String, Object?> message) {
    final secure = ch.secure;
    if (secure == null || _channels[channel] != ch) return;
    unawaited(secure.seal(Tunnel.encode(message), (frame) => _send(channel, frame)).then((_) {}, onError: (_) {}));
  }

  void _handle(int channel, _Channel ch, Map<String, Object?> m) {
    final id = m['id'];
    if (id is! int) return;
    switch (m['t']) {
      case Tunnel.request:
        unawaited(_request(channel, ch, id, m));
      case Tunnel.socketOpen:
        unawaited(_openSocket(channel, ch, id, m['path'] as String? ?? ''));
      case Tunnel.socketData:
        final data = m['data'];
        if (data is String && !_isAuthFrame(data)) ch.sockets[id]?.sendText(data);
      case Tunnel.socketClose:
        unawaited(ch.sockets.remove(id)?.close().catchError((Object _) {}));
    }
  }

  Future<void> _request(int channel, _Channel ch, int id, Map<String, Object?> m) async {
    final method = (m['method'] as String? ?? 'GET').toUpperCase();
    final path = m['path'] as String? ?? '';
    var body = m['body'] as String?;
    void respond(int status, String body) =>
        _reply(channel, ch, {'t': Tunnel.response, 'id': id, 'status': status, 'body': body});

    if (!const {'GET', 'POST', 'DELETE'}.contains(method) || !allowedRestPath(path)) {
      return respond(403, jsonEncode({'message': 'Not reachable from a remote device.'}));
    }
    if (path == 'everyai/projects') {
      return respond(
        200,
        jsonEncode([
          for (final p in _projects()) {'name': p.name, 'path': p.path},
        ]),
      );
    }
    if (method == 'POST' && Uri.parse(path).path == 'api/conversations' && body != null) {
      final rewritten = _workspaceIn(body);
      if (rewritten == null) {
        return respond(403, jsonEncode({'message': "That folder isn't one of the host's projects."}));
      }
      body = rewritten;
    }
    try {
      final (base, key) = await _locate();
      final req = http.Request(method, base.resolve(path))
        ..headers.addAll({'X-Session-API-Key': key, 'Content-Type': 'application/json'});
      if (body != null) req.body = body;
      final res = await http.Response.fromStream(await _http.send(req));
      respond(res.statusCode, res.body);
    } on Object catch (e) {
      respond(502, jsonEncode({'message': "The host's agent server isn't reachable: $e"}));
    }
  }

  /// [body] with the working folder as a host path, or null when the device
  /// asked for a folder the host doesn't offer.
  String? _workspaceIn(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?>) return null;
    final workspace = decoded['workspace'];
    if (workspace is! Map<String, Object?>) return null;
    final dir = workspace['working_dir'];
    if (dir is! String) return null;
    final remote = parseRemotePath(dir);
    if (remote != null && remote.hostId != hostId) return null;
    final local = remote?.path ?? dir;
    if (!_allowedDir(local)) return null;
    workspace['working_dir'] = local;
    return jsonEncode(decoded);
  }

  Future<void> _openSocket(int channel, _Channel ch, int id, String path) async {
    void closed(String reason) {
      if (ch.sockets.containsKey(id) || reason.isNotEmpty) {
        ch.sockets.remove(id);
        _reply(channel, ch, {'t': Tunnel.socketClosed, 'id': id, 'reason': reason});
      }
    }

    if (!allowedSocketPath(path)) return closed('Not reachable from a remote device.');
    final WebSocket socket;
    try {
      final (base, key) = await _locate();
      final target = Uri.parse(path);
      final url = base.replace(
        scheme: base.scheme == 'https' ? 'wss' : 'ws',
        path: '${base.path.replaceAll(RegExp(r'/$'), '')}/${target.path}',
        queryParameters: target.queryParameters.isEmpty ? null : target.queryParameters,
      );
      socket = await _connectSocket(url);
      socket.sendText(jsonEncode({'type': 'auth', 'session_api_key': key}));
    } on Object catch (e) {
      return closed("The host's agent server isn't reachable: $e");
    }
    if (_channels[channel] != ch) {
      unawaited(socket.close().catchError((Object _) {}));
      return;
    }
    ch.sockets[id] = socket;
    _reply(channel, ch, {'t': Tunnel.socketReady, 'id': id});
    socket.events.listen(
      (event) {
        switch (event) {
          case TextDataReceived(:final text):
            _reply(channel, ch, {'t': Tunnel.socketData, 'id': id, 'data': text});
          case BinaryDataReceived():
            break;
          case CloseReceived():
            closed('');
        }
      },
      onError: (_) => closed(''),
      onDone: () => closed(''),
    );
  }

  static bool _isAuthFrame(String data) {
    if (!data.contains('"auth"')) return false;
    try {
      final decoded = jsonDecode(data);
      return decoded is Map && decoded['type'] == 'auth';
    } on FormatException {
      return false;
    }
  }
}

final class _Channel {
  _Channel(this.deviceId, this.publicKey);
  final String deviceId;
  final List<int> publicKey;
  SecureChannel? secure;
  final sockets = <int, WebSocket>{};

  void reset() {
    secure = null;
    for (final s in sockets.values) {
      unawaited(s.close().catchError((Object _) {}));
    }
    sockets.clear();
  }
}
