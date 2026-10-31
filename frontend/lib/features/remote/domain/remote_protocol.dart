import 'dart:convert';
import 'dart:typed_data';

/// What travels inside the encrypted frames between a device and its host:
/// one JSON object per frame, `t` naming the kind.
///
/// The host runs every Code session; a device (phone, tablet, browser)
/// mirrors them and sends the user's actions back. Nothing runs on the device.
///
/// Device → host:
/// - `{t:"list"}`: the host sends `sessions` now and again whenever they change.
/// - `{t:"open", s}`: mirror session `s`: a `reset`, its log as `events`,
///   then live `events` and `state`.
/// - `{t:"close", s}`: stop mirroring it.
/// - `{t:"act", id, s, kind, args}`: one of [MirrorAction] on session `s`;
///   answered with `done`.
///
/// Host → device:
/// - `{t:"sessions", host, projects:[{id, name}], sessions:[{…session, status}]}`.
/// - `{t:"reset", s}`: the log starts over (opening, a compaction, a rewind).
/// - `{t:"events", s, events:[…]}`: agent-server events, in order (deltas too).
/// - `{t:"state", s, …}`: what the transcript doesn't carry (see `HostMirror`).
/// - `{t:"gone", s, message}`: the session isn't on the host (any more).
/// - `{t:"done", id, error?}`.
abstract final class Tunnel {
  static const list = 'list';
  static const open = 'open';
  static const close = 'close';
  static const act = 'act';
  static const sessions = 'sessions';
  static const reset = 'reset';
  static const events = 'events';
  static const state = 'state';
  static const gone = 'gone';
  static const done = 'done';

  static Uint8List encode(Map<String, Object?> message) => utf8.encode(jsonEncode(message));

  /// The most plaintext one sealed frame carries. The relay drops a socket
  /// whose frame passes 4 MiB, so bigger messages (a long event, an
  /// attached photo) go out in parts.
  static const maxPart = 1 << 20;

  static const _more = 0x00;
  static const _last = 0x01;

  /// [message] as the plaintexts to seal, in order: the JSON itself when it
  /// fits in [maxPart], else parts marked `00` (more follows) and `01`
  /// (the last). Seal them back to back, so no other message comes between.
  static List<Uint8List> split(Map<String, Object?> message, {int maxPart = maxPart}) {
    final bytes = encode(message);
    if (bytes.length <= maxPart) return [bytes];
    final step = maxPart - 1;
    final parts = <Uint8List>[];
    for (var at = 0; at < bytes.length; at += step) {
      final end = at + step < bytes.length ? at + step : bytes.length;
      parts.add(
        Uint8List(1 + end - at)
          ..[0] = end == bytes.length ? _last : _more
          ..setRange(1, 1 + end - at, bytes, at),
      );
    }
    return parts;
  }

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

/// Puts [Tunnel.split] parts back together, one direction of one channel.
final class TunnelAssembler {
  TunnelAssembler({this.maxMessage = 64 << 20});

  /// A message longer than this is dropped (its parts are skipped).
  final int maxMessage;
  final _parts = BytesBuilder(copy: false);
  bool _tooLong = false;

  /// The message [plaintext] completes, or null (a part, junk, or too long).
  Map<String, Object?>? add(Uint8List plaintext) {
    if (plaintext.isEmpty) return null;
    final marker = plaintext[0];
    if (marker != Tunnel._more && marker != Tunnel._last) {
      // A whole message; a half-built one before it is gone.
      reset();
      return Tunnel.decode(plaintext);
    }
    if (!_tooLong) {
      if (_parts.length + plaintext.length - 1 > maxMessage) {
        _tooLong = true;
        _parts.clear();
      } else {
        _parts.add(Uint8List.sublistView(plaintext, 1));
      }
    }
    if (marker == Tunnel._more) return null;
    final whole = _tooLong ? null : _parts.takeBytes();
    reset();
    return whole == null ? null : Tunnel.decode(whole);
  }

  void reset() {
    _parts.clear();
    _tooLong = false;
  }
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

/// What a device can ask the host to do in a session (`act`'s `kind`).
abstract final class MirrorAction {
  /// `{text, files?:[{name, mime, data (base64)}]}`: queued while the agent works.
  static const send = 'send';

  /// `{text, files?}`: interrupts and sends now.
  static const steer = 'steer';
  static const stop = 'stop';

  /// `{scope: once|session|always}` for the pending approval.
  static const approve = 'approve';

  /// `{reason}`.
  static const deny = 'deny';

  /// `{call, answers:[{selected:[i], other}]}` for the question card of tool call `call`.
  static const answer = 'answer';

  /// `{mode}` (an `AgentMode` name).
  static const mode = 'mode';

  /// Plan mode's Start building.
  static const build = 'build';
  static const retry = 'retry';

  /// `{index}` of a queued message.
  static const unqueue = 'unqueue';
}
