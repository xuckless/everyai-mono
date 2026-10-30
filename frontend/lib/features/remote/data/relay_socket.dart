import 'package:web_socket/web_socket.dart';

import 'relay_socket_web.dart' if (dart.library.io) 'relay_socket_io.dart' as impl;

/// Opens a relay socket at [url] with [token]: in the `Authorization` header
/// where the platform allows it, else as `?token=` (browsers can't set
/// headers on a WebSocket).
Future<WebSocket> connectRelay(Uri url, String token) => impl.connectRelay(url, token);

/// The relay's WebSocket URL for [path] (`v1/remote/host`) under the API base.
Uri relayUrl(Uri apiBase, String path) {
  final url = apiBase.resolve(path);
  return url.replace(scheme: url.scheme == 'https' ? 'wss' : 'ws');
}
