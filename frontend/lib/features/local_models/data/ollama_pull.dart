// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'local_http.dart';

/// Where one model download stands.
enum DownloadPhase { queued, running, done, failed, cancelled }

@immutable
final class DownloadState {
  const DownloadState({
    required this.tag,
    this.phase = DownloadPhase.queued,
    this.status,
    this.done,
    this.total,
    this.error,
  });
  final String tag;
  final DownloadPhase phase;

  /// Ollama's own words ("pulling manifest", "verifying sha256 digest").
  final String? status;
  final int? done;
  final int? total;
  final String? error;

  /// 0–1 when the size is known.
  double? get fraction => total == null || total == 0 || done == null ? null : (done! / total!).clamp(0.0, 1.0);

  bool get active => phase == DownloadPhase.queued || phase == DownloadPhase.running;

  DownloadState copyWith({DownloadPhase? phase, String? status, int? done, int? total, String? error}) => DownloadState(
    tag: tag,
    phase: phase ?? this.phase,
    status: status ?? this.status,
    done: done ?? this.done,
    total: total ?? this.total,
    error: error ?? this.error,
  );
}

/// How long a pull may go without a line from Ollama before it fails as stalled (a layer's progress comes several
/// times a second, verifying a big one well within this).
const pullStallTimeout = Duration(minutes: 2);

/// The stall limit while Ollama works without a word: after a `verifying sha256 digest` or `writing manifest` line it
/// hashes or writes the whole layer before the next one, which takes many minutes for a very large layer.
const pullQuietStallTimeout = Duration(minutes: 30);

/// Whether [status] (the last line's) starts one of Ollama's silent steps ([pullQuietStallTimeout]).
bool pullStatusIsQuiet(String? status) {
  final st = (status ?? '').trimLeft().toLowerCase();
  return st.startsWith('verifying') || st.startsWith('writing');
}

/// One line of Ollama's `/api/pull` stream: `{status, digest?, total?, completed?}`, `{status: "success"}` at the
/// end, or `{error}`. Layers report one by one, so the bytes shown are the current layer's.
DownloadState applyPullLine(DownloadState s, String line) {
  final Object? d;
  try {
    d = jsonDecode(line);
  } on FormatException {
    return s;
  }
  if (d is! Map<String, Object?>) return s;
  if (d['error'] case final String e) return s.copyWith(phase: DownloadPhase.failed, error: e);
  final status = d['status'] as String?;
  if (status == 'success') return s.copyWith(phase: DownloadPhase.done, status: 'Ready', done: s.total);
  return s.copyWith(
    phase: DownloadPhase.running,
    status: status,
    total: (d['total'] as num?)?.toInt(),
    done: (d['completed'] as num?)?.toInt() ?? (d['total'] == null ? null : 0),
  );
}

/// Pulls [tag] from the Ollama server at [ollamaRoot] (`http://127.0.0.1:11434`), reporting each step. Ollama keeps
/// the layers it already has, so pulling again after a cancel picks up where it stopped. Cancelling the subscription
/// ends the request at once (not an `async*`, which would wait for the next line first). A pull that sends no line
/// for [stallAfter] fails as stalled (the request is ended; Download again resumes it); after a line that starts a
/// silent step (verifying, writing) the limit is [quietStallAfter].
Stream<DownloadState> pullModel(
  LocalHttp http,
  Uri ollamaRoot,
  String tag, {
  Duration stallAfter = pullStallTimeout,
  Duration quietStallAfter = pullQuietStallTimeout,
}) {
  late final StreamController<DownloadState> out;
  StreamSubscription<String>? lines;
  Timer? stall;
  var s = DownloadState(tag: tag, phase: DownloadPhase.running, status: 'Starting');
  void finish(DownloadState last) {
    stall?.cancel();
    if (out.isClosed) return;
    out.add(last);
    unawaited(lines?.cancel());
    out.close();
  }

  void watch() {
    stall?.cancel();
    final limit = pullStatusIsQuiet(s.status) ? quietStallAfter : stallAfter;
    stall = Timer(
      limit,
      () => finish(
        s.copyWith(phase: DownloadPhase.failed, error: 'stalled: Ollama sent nothing for ${limit.inSeconds} s'),
      ),
    );
  }

  out = StreamController<DownloadState>(
    onListen: () {
      out.add(s);
      watch();
      lines = http
          .postLines(ollamaRoot.replace(path: '/api/pull'), {'model': tag, 'stream': true})
          .listen(
            (line) {
              if (out.isClosed) return;
              if (line.trim().isNotEmpty) s = applyPullLine(s, line);
              // After the line: its status picks the limit (a silent step gets the long one).
              watch();
              if (line.trim().isEmpty) return;
              if (s.phase == DownloadPhase.failed || s.phase == DownloadPhase.done) {
                finish(s);
              } else {
                out.add(s);
              }
            },
            onError: (Object e) => finish(s.copyWith(phase: DownloadPhase.failed, error: '$e')),
            onDone: () => finish(
              s.phase == DownloadPhase.running
                  ? s.copyWith(phase: DownloadPhase.failed, error: 'The download stopped')
                  : s,
            ),
          );
    },
    onCancel: () {
      stall?.cancel();
      return lines?.cancel();
    },
  );
  return out.stream;
}

/// Deletes [tag] from Ollama. Null when it worked, else why not.
Future<String?> deleteModel(LocalHttp http, Uri ollamaRoot, String tag) async {
  final res = await http.send(
    'DELETE',
    ollamaRoot.replace(path: '/api/delete'),
    json: {'model': tag},
    timeout: const Duration(seconds: 10),
  );
  if (res == null) return "Ollama didn't answer";
  if (res.ok) return null;
  return LocalHttpError(res.status, res.body).toString();
}
