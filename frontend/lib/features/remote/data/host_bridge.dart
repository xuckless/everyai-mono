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
/// conversation API and event sockets are reachable, a conversation can
/// only start in a folder [allowedDir] accepts, and an existing one is only
/// reachable (and listed) when its folder is one [allowedDir] accepts.
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
      // Inits are worked out concurrently: only the newest one is answered,
      // so the device and this side end up on the same keys.
      final seq = ++ch.handshakes;
      try {
        final (accept, secure) = await acceptHandshake(identity, ch.publicKey, payload);
        if (_channels[channel] != ch || ch.handshakes != seq) return;
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
        final message = ch.incoming.add(clear);
        if (message != null) _handle(channel, ch, message);
      });
    } on RemoteCryptoError {
      // Tampered or replayed: dropped.
    }
  }

  void _reply(int channel, _Channel ch, Map<String, Object?> message) {
    final secure = ch.secure;
    if (secure == null || _channels[channel] != ch) return;
    // Back to back, so a long message's parts are never split up by another.
    for (final part in Tunnel.split(message)) {
      unawaited(secure.seal(part, (frame) => _send(channel, frame)).then((_) {}, onError: (_) {}));
    }
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
    final starting = method == 'POST' && Uri.parse(path).path == 'api/conversations';
    if (starting) {
      final rewritten = body == null ? null : _workspaceIn(body);
      if (rewritten == null) {
        return respond(403, jsonEncode({'message': "That folder isn't one of the host's projects."}));
      }
      body = rewritten;
    }
    try {
      if (conversationInPath(path) case final id?) {
        final refused = await _refusal(ch, id);
        if (refused != null) return respond(refused.status, refused.body);
      }
      final res = await _forward(method, path, body);
      if (starting && res.statusCode == 200) {
        // It started in a folder that was checked above.
        if (_idIn(res.body) case final id?) ch.conversations[id] = true;
      }
      final listing = method == 'GET' && Uri.parse(path).path == 'api/conversations' && res.statusCode == 200;
      respond(res.statusCode, listing ? await _listed(ch, res.body) : res.body);
    } on Object catch (e) {
      respond(502, jsonEncode({'message': "The host's agent server isn't reachable: $e"}));
    }
  }

  Future<http.Response> _forward(String method, String path, String? body) async {
    final (base, key) = await _locate();
    final req = http.Request(method, base.resolve(path))
      ..headers.addAll({'X-Session-API-Key': key, 'Content-Type': 'application/json'});
    if (body != null) req.body = body;
    return http.Response.fromStream(await _http.send(req));
  }

  static String? _idIn(String body) {
    try {
      return switch (jsonDecode(body)) {
        {'id': final String id} => id,
        _ => null,
      };
    } on FormatException {
      return null;
    }
  }

  /// Why the device may not reach conversation [id] (its folder isn't one
  /// the host offers), as the answer to send; null when it may. Looked up
  /// once per channel.
  Future<({int status, String body})?> _refusal(_Channel ch, String id) async {
    final known = ch.conversations[id];
    if (known != null) return known ? null : _notOffered;
    final res = await _forward('GET', 'api/conversations/$id', null);
    if (res.statusCode != 200) return (status: res.statusCode, body: res.body);
    final allowed = _inOfferedFolder(res.body);
    ch.conversations[id] = allowed;
    return allowed ? null : _notOffered;
  }

  static final _notOffered = (
    status: 403,
    body: jsonEncode({'message': "That session isn't in one of the host's projects."}),
  );

  bool _inOfferedFolder(String info) {
    try {
      final decoded = jsonDecode(info);
      if (decoded case {'workspace': {'working_dir': final String dir}}) {
        final local = normalizeHostPath(dir);
        return local != null && _allowedDir(local);
      }
    } on FormatException {
      return false;
    }
    return false;
  }

  /// A conversation list with only the conversations the device may reach.
  Future<String> _listed(_Channel ch, String body) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return '[]';
    }
    Future<List<Object?>> keep(List<Object?> items) async {
      final out = <Object?>[];
      for (final item in items) {
        if (item case {'id': final String id} when await _refusal(ch, id) == null) out.add(item);
      }
      return out;
    }

    if (decoded is List<Object?>) return jsonEncode(await keep(decoded));
    if (decoded case {'items': final List<Object?> items}) {
      return jsonEncode({...decoded, 'items': await keep(items)});
    }
    return '[]';
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
    // `..` can't step out of a project: the folder is checked as the server will see it.
    final local = normalizeHostPath(remote?.path ?? dir);
    if (local == null || !_allowedDir(local)) return null;
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
      if (conversationInPath(path) case final id?) {
        if (await _refusal(ch, id) != null) return closed("That session isn't in one of the host's projects.");
      }
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

  /// Handshake inits received, to answer only the newest.
  int handshakes = 0;

  /// Puts the device's long messages back together.
  final incoming = TunnelAssembler();

  /// Conversations checked for this device: whether it may reach each.
  final conversations = <String, bool>{};

  void reset() {
    secure = null;
    incoming.reset();
    for (final s in sockets.values) {
      unawaited(s.close().catchError((Object _) {}));
    }
    sockets.clear();
  }
}
