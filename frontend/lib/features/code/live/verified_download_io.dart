// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';

import 'package:crypto/crypto.dart';

/// Downloads [url] to [to] and checks it against the pinned SHA-256 [sha] (our own hash of the file, taken when it
/// was pinned); a mismatch deletes the file and throws. [onProgress] gets 0…1 of the download.
Future<void> downloadVerified(Uri url, String sha, File to, {void Function(double progress)? onProgress}) async {
  to.parent.createSync(recursive: true);
  final client = HttpClient();
  try {
    final res = await (await client.getUrl(url)).close();
    if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}', uri: url);
    final total = res.contentLength;
    var got = 0;
    final sink = to.openWrite();
    final digest = _DigestSink();
    final hasher = sha256.startChunkedConversion(digest);
    await for (final chunk in res) {
      sink.add(chunk);
      hasher.add(chunk);
      got += chunk.length;
      if (total > 0) onProgress?.call(got / total);
    }
    hasher.close();
    await sink.close();
    if ('${digest.value}' != sha) {
      to.deleteSync();
      throw StateError('the download of $url does not match its pinned SHA-256, so it was deleted');
    }
  } finally {
    client.close(force: true);
  }
}

final class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
