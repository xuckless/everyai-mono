// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// One answer from a local server.
final class LocalReply {
  const LocalReply(this.status, this.body);
  final int status;
  final String body;

  bool get ok => status >= 200 && status < 300;

  /// The body as a JSON object, null when it isn't one.
  Map<String, Object?>? get json {
    try {
      final d = jsonDecode(body);
      return d is Map<String, Object?> ? d : null;
    } on FormatException {
      return null;
    }
  }
}

/// The HTTP the local-model code needs; tests replace it with a fake.
abstract interface class LocalHttp {
  /// Null when nothing answered in time (refused, timed out).
  Future<LocalReply?> get(Uri url, {Map<String, String> headers = const {}, Duration? timeout});

  Future<LocalReply?> send(
    String method,
    Uri url, {
    Object? json,
    Map<String, String> headers = const {},
    Duration? timeout,
  });

  /// A streamed POST read line by line (Ollama's `/api/pull`). Cancelling the subscription ends the request.
  Stream<String> postLines(Uri url, Object json);
}

/// [LocalHttp] over package:http. Short timeouts: a scan probes ports that are usually closed.
final class RealLocalHttp implements LocalHttp {
  const RealLocalHttp();

  static const probeTimeout = Duration(milliseconds: 1500);

  @override
  Future<LocalReply?> get(Uri url, {Map<String, String> headers = const {}, Duration? timeout}) =>
      send('GET', url, headers: headers, timeout: timeout);

  @override
  Future<LocalReply?> send(
    String method,
    Uri url, {
    Object? json,
    Map<String, String> headers = const {},
    Duration? timeout,
  }) async {
    final wait = timeout ?? probeTimeout;
    final client = http.Client();
    try {
      final req = http.Request(method, url)..headers.addAll(headers);
      if (json != null) {
        req.headers['Content-Type'] = 'application/json';
        req.body = jsonEncode(json);
      }
      final res = await client.send(req).timeout(wait);
      final body = await res.stream.bytesToString().timeout(wait);
      return LocalReply(res.statusCode, body);
    } on Object {
      return null;
    } finally {
      client.close();
    }
  }

  @override
  Stream<String> postLines(Uri url, Object json) {
    late final StreamController<String> out;
    http.Client? client;
    StreamSubscription<String>? sub;
    out = StreamController<String>(
      onListen: () async {
        client = http.Client();
        try {
          final req = http.Request('POST', url)
            ..headers['Content-Type'] = 'application/json'
            ..body = jsonEncode(json);
          final res = await client!.send(req);
          if (res.statusCode >= 300) {
            final body = await res.stream.bytesToString();
            out.addError(LocalHttpError(res.statusCode, body));
            await out.close();
            return;
          }
          sub = res.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .listen(
                out.add,
                onError: out.addError,
                onDone: () {
                  client?.close();
                  out.close();
                },
              );
        } on Object catch (e) {
          if (!out.isClosed) {
            out.addError(e);
            await out.close();
          }
        }
      },
      onCancel: () async {
        await sub?.cancel();
        client?.close();
      },
    );
    return out.stream;
  }
}

final class LocalHttpError implements Exception {
  const LocalHttpError(this.status, this.body);
  final int status;
  final String body;

  @override
  String toString() {
    try {
      final d = jsonDecode(body);
      if (d is Map && d['error'] is String) return d['error'] as String;
    } on FormatException {
      // Not JSON: the raw body below.
    }
    return 'HTTP $status${body.isEmpty ? '' : ': $body'}';
  }
}
