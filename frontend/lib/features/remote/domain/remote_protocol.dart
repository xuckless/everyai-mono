import 'dart:convert';
import 'dart:typed_data';

/// What travels inside the encrypted frames between a device and its host:
/// one JSON object per frame, `t` naming the kind.
///
/// The host bridges these to its local agent-server, so a device reaches the
/// same REST and event socket a desktop session uses, without ever learning
/// the server's address or key.
///
/// Device → host:
/// - `{t:"req", id, method, path, body?}`: a REST call (`api/conversations…`)
///   or a host route (`everyai/projects`).
/// - `{t:"ws_open", id, path}`: open the event socket at `sockets/events/<id>…`.
/// - `{t:"ws", id, data}`: a text frame on that socket.
/// - `{t:"ws_close", id}`.
///
/// Host → device:
/// - `{t:"res", id, status, body}`.
/// - `{t:"ws_ready", id}`, `{t:"ws", id, data}`, `{t:"ws_closed", id, reason?}`.
abstract final class Tunnel {
  static const request = 'req';
  static const response = 'res';
  static const socketOpen = 'ws_open';
  static const socketReady = 'ws_ready';
  static const socketData = 'ws';
  static const socketClose = 'ws_close';
  static const socketClosed = 'ws_closed';

  static Uint8List encode(Map<String, Object?> message) => utf8.encode(jsonEncode(message));

  /// The message in [bytes], or null if it isn't one.
  static Map<String, Object?>? decode(List<int> bytes) {
    try {
      final value = jsonDecode(utf8.decode(bytes));
      return value is Map<String, Object?> && value['t'] is String ? value : null;
    } on FormatException {
      return null;
    }
  }
}

/// Host routes a device may call: the agent-server's conversations API, its
/// event sockets, and the host's own `everyai/…` answers.
bool allowedRestPath(String path) {
  final p = Uri.parse(path).path;
  if (p.contains('..')) return false;
  return p == 'api/conversations' || p.startsWith('api/conversations/') || p == 'everyai/projects';
}

bool allowedSocketPath(String path) {
  final p = Uri.parse(path).path;
  return !p.contains('..') && RegExp(r'^sockets/events/[A-Za-z0-9_-]+$').hasMatch(p);
}

// ------------------------------------------------------------------ pairing

/// What the host's QR code carries: the code, the host, and its key's
/// fingerprint, so the device can check the key the backend hands it.
final class PairingPayload {
  const PairingPayload({required this.code, this.hostId, this.fingerprint, this.hostName});

  /// As typed or scanned (the backend ignores case, dashes and spaces).
  final String code;
  final String? hostId;
  final String? fingerprint;
  final String? hostName;

  static const scheme = 'everyai';

  String toUri() => Uri(
    scheme: scheme,
    host: 'pair',
    queryParameters: {'c': code, 'h': ?hostId, 'fp': ?fingerprint, 'n': ?hostName},
  ).toString();

  /// A scanned QR payload or a typed code; null for neither.
  static PairingPayload? parse(String text) {
    final trimmed = text.trim();
    if (trimmed.startsWith('$scheme://')) {
      final uri = Uri.tryParse(trimmed);
      final code = uri?.queryParameters['c'];
      if (uri == null || uri.host != 'pair' || code == null || normalizeCode(code) == null) return null;
      return PairingPayload(
        code: code,
        hostId: uri.queryParameters['h'],
        fingerprint: uri.queryParameters['fp'],
        hostName: uri.queryParameters['n'],
      );
    }
    return normalizeCode(trimmed) == null ? null : PairingPayload(code: trimmed);
  }
}

/// The backend's code alphabet: 8 symbols, no I, O, 0 or 1.
const _codeAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

/// [typed] as the backend stores it (upper case, no dashes or spaces), or
/// null when it can't be a code.
String? normalizeCode(String typed) {
  final code = typed.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
  if (code.length != 8) return null;
  for (final ch in code.split('')) {
    if (!_codeAlphabet.contains(ch)) return null;
  }
  return code;
}

/// `ABCD-EFGH` for display.
String displayCode(String code) {
  final n = normalizeCode(code) ?? code;
  return n.length == 8 ? '${n.substring(0, 4)}-${n.substring(4)}' : n;
}

// ------------------------------------------------------------------ remote projects

/// Projects on a remote host are stored with this scheme: `remote://<host id>/<path on the host>`.
const remoteScheme = 'remote://';

bool isRemotePath(String path) => path.startsWith(remoteScheme);

String remotePath(String hostId, String hostPath) => '$remoteScheme$hostId/$hostPath';

/// The host and the folder on it, or null for a local path.
({String hostId, String path})? parseRemotePath(String path) {
  if (!isRemotePath(path)) return null;
  final rest = path.substring(remoteScheme.length);
  final slash = rest.indexOf('/');
  if (slash <= 0) return null;
  return (hostId: rest.substring(0, slash), path: rest.substring(slash + 1));
}
