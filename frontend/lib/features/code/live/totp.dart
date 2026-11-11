// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:typed_data';

import 'package:crypto/crypto.dart';

// Authenticator codes (TOTP, RFC 6238) for saved logins: the secret an authenticator app was set up with (base32, or
// the whole `otpauth://totp/…` address its QR code holds) gives the code of the moment.

/// The hash a TOTP secret uses.
enum TotpHash { sha1, sha256, sha512 }

/// A parsed authenticator secret: its key, hash, number of digits and period.
typedef TotpSpec = ({List<int> key, TotpHash hash, int digits, int period});

/// [secret] (base32, spaces and dashes allowed, or an `otpauth://totp/…?secret=…` address) as a [TotpSpec], or null
/// when it isn't one.
TotpSpec? parseTotp(String secret) {
  final s = secret.trim();
  if (s.isEmpty) return null;
  if (s.toLowerCase().startsWith('otpauth://')) {
    final uri = Uri.tryParse(s);
    if (uri == null || uri.host.toLowerCase() != 'totp') return null;
    final q = {for (final e in uri.queryParameters.entries) e.key.toLowerCase(): e.value};
    final key = base32Decode(q['secret'] ?? '');
    if (key == null || key.isEmpty) return null;
    final hash = switch ((q['algorithm'] ?? 'SHA1').toUpperCase()) {
      'SHA1' => TotpHash.sha1,
      'SHA256' => TotpHash.sha256,
      'SHA512' => TotpHash.sha512,
      _ => null,
    };
    final digits = int.tryParse(q['digits'] ?? '6');
    final period = int.tryParse(q['period'] ?? '30');
    if (hash == null || digits == null || digits < 6 || digits > 10 || period == null || period < 1) return null;
    return (key: key, hash: hash, digits: digits, period: period);
  }
  final key = base32Decode(s);
  if (key == null || key.length < 10) return null;
  return (key: key, hash: TotpHash.sha1, digits: 6, period: 30);
}

/// Base32 (RFC 4648) [text] as bytes; spaces, dashes and padding are ignored, case too. Null when it isn't base32.
List<int>? base32Decode(String text) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  final clean = text.toUpperCase().replaceAll(RegExp(r'[\s=-]'), '');
  if (clean.isEmpty) return null;
  final out = <int>[];
  var buffer = 0, bits = 0;
  for (final ch in clean.split('')) {
    final v = alphabet.indexOf(ch);
    if (v < 0) return null;
    buffer = (buffer << 5) | v;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      out.add((buffer >> bits) & 0xff);
    }
    buffer &= (1 << bits) - 1;
  }
  return out;
}

/// The code [spec] gives at [at] (now when null).
String totpCode(TotpSpec spec, {DateTime? at}) {
  final seconds = (at ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
  final counter = seconds ~/ spec.period;
  // Two 32-bit halves: setUint64 doesn't run on the web.
  final msg = ByteData(8)
    ..setUint32(0, counter ~/ 0x100000000)
    ..setUint32(4, counter % 0x100000000);
  final hmac = Hmac(switch (spec.hash) {
    TotpHash.sha1 => sha1,
    TotpHash.sha256 => sha256,
    TotpHash.sha512 => sha512,
  }, spec.key);
  final h = hmac.convert(msg.buffer.asUint8List()).bytes;
  final offset = h.last & 0x0f;
  final value =
      ((h[offset] & 0x7f) << 24) |
      ((h[offset + 1] & 0xff) << 16) |
      ((h[offset + 2] & 0xff) << 8) |
      (h[offset + 3] & 0xff);
  var mod = 1;
  for (var i = 0; i < spec.digits; i++) {
    mod *= 10;
  }
  return (value % mod).toString().padLeft(spec.digits, '0');
}

/// Seconds the code of [spec] at [at] still holds.
int totpSecondsLeft(TotpSpec spec, {DateTime? at}) {
  final seconds = (at ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
  return spec.period - seconds % spec.period;
}
