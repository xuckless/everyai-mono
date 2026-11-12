// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// How long a download may go without a byte before it fails (a stalled connection would otherwise wait forever).
const downloadIdleTimeout = Duration(seconds: 60);

/// Downloads [url] to [to] and checks it against the pinned SHA-256 [sha] (our own hash of the file, taken when it
/// was pinned); a mismatch deletes the file and throws. [onProgress] gets 0…1 of the download. The connection, the
/// answer and every read must come within [idle]; a download that fails or stalls leaves no file behind.
Future<void> downloadVerified(
  Uri url,
  String sha,
  File to, {
  void Function(double progress)? onProgress,
  Duration idle = downloadIdleTimeout,
}) async {
  to.parent.createSync(recursive: true);
  final client = HttpClient()
    ..connectionTimeout = idle
    ..idleTimeout = idle;
  IOSink? sink;
  var ok = false;
  try {
    final res = await (await client.getUrl(url).timeout(idle)).close().timeout(idle);
    if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}', uri: url);
    final total = res.contentLength;
    var got = 0;
    sink = to.openWrite();
    final digest = _DigestSink();
    final hasher = sha256.startChunkedConversion(digest);
    await for (final chunk in res.timeout(
      idle,
      onTimeout: (s) => s.addError(TimeoutException('the download of $url stalled (no data for ${idle.inSeconds} s)')),
    )) {
      sink.add(chunk);
      hasher.add(chunk);
      got += chunk.length;
      if (total > 0) onProgress?.call(got / total);
    }
    hasher.close();
    await sink.close();
    sink = null;
    if ('${digest.value}' != sha) {
      throw StateError('the download of $url does not match its pinned SHA-256, so it was deleted');
    }
    ok = true;
  } finally {
    client.close(force: true);
    if (!ok) {
      try {
        await sink?.close();
      } on Object {
        // The file goes below either way.
      }
      if (to.existsSync()) to.deleteSync();
    }
  }
}

/// Downloads in flight, by target path: a second ask for the same file joins the first.
final _inFlight = <String, Future<void>>{};

/// [downloadVerified] into `<target>.part`, renamed to [target] once checked: [target] exists only complete and
/// verified. One download per target at a time (callers asking meanwhile join it).
Future<void> downloadVerifiedTo(Uri url, String sha, File target, {void Function(double progress)? onProgress}) {
  final key = target.absolute.path;
  if (_inFlight[key] case final f?) return f;
  late final Future<void> f;
  f =
      () async {
        final part = File('${target.path}.part');
        await downloadVerified(url, sha, part, onProgress: onProgress);
        await part.rename(target.path);
      }().whenComplete(() {
        if (identical(_inFlight[key], f)) _inFlight.remove(key);
      });
  return _inFlight[key] = f;
}

final class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
