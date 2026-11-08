// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

import 'local_backend.dart';

LocalBackend createLocalBackend() => IoLocalBackend();

/// Where the bundled server binary is: `EVERYAI_BACKEND_BIN`, the macOS
/// bundle's Resources, next to the app's executable (Windows, Linux), or the
/// dev build from `tool/build_local_backend.sh` (`frontend/.local-backend/`).
String? findLocalBackend({Map<String, String>? env, String? exe, String? cwd, bool Function(String)? exists}) {
  env ??= Platform.environment;
  final exeDir = File(exe ?? Platform.resolvedExecutable).parent.path;
  final name = Platform.isWindows ? 'everyai-backend.exe' : 'everyai-backend';
  final candidates = [
    ?env['EVERYAI_BACKEND_BIN'],
    if (Platform.isMacOS) '$exeDir/../Resources/$name',
    '$exeDir/$name',
    '${cwd ?? Directory.current.path}/.local-backend/$name',
  ];
  final has = exists ?? (String p) => File(p).existsSync();
  for (final c in candidates) {
    if (c.isNotEmpty && has(c)) return c;
  }
  return null;
}

String _randomHex(int bytes) {
  final r = Random.secure();
  return [for (var i = 0; i < bytes; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
}

final class IoLocalBackend implements LocalBackend {
  IoLocalBackend({this.binary, this.dataDir});

  /// Overrides for tests.
  final String? binary;
  final String? dataDir;

  BackendPhase _phase = const BackendIdle();
  Process? _process;
  String? _dir;
  Future<LocalBackendInfo?>? _starting;
  final _recentCrashes = <DateTime>[];

  @override
  BackendPhase get phase => _phase;

  @override
  String? get problem => switch (_phase) {
    BackendUnavailable(:final reason) || BackendCrashed(:final reason) => reason,
    BackendClosed() => 'EveryAI is quitting.',
    _ => null,
  };

  @override
  bool get running => _phase is BackendRunning;

  bool _apply(BackendEvent e) {
    final next = nextBackendPhase(_phase, e);
    if (next == null) return false;
    _phase = next;
    return true;
  }

  @override
  Future<LocalBackendInfo?> ensureStarted() {
    if (_phase case BackendRunning(:final info)) return Future.value(info);
    if (_starting case final s?) return s;
    if (!_apply(const BackendStartAsked())) return Future.value(null);
    return _starting = _start().whenComplete(() => _starting = null);
  }

  Future<LocalBackendInfo?> _start() async {
    final bin = binary ?? findLocalBackend();
    if (bin == null) {
      _apply(const BackendStartFailed("This build doesn't include the built-in server."));
      return null;
    }
    final dir = _dir = dataDir ?? '${(await getApplicationSupportDirectory()).path}/local-backend';
    await Directory(dir).create(recursive: true);
    await _killOrphan(dir);
    if (_phase is! BackendStarting) return null; // Closed or stopped meanwhile.
    final port = await _freePort();
    final token = _randomHex(24);
    final Process process;
    try {
      process = await Process.start(
        bin,
        const [],
        workingDirectory: dir,
        environment: {
          'ANOLE_ENV': 'production',
          'LOCAL_MODE': 'true',
          'LOCAL_TOKEN': token,
          // The server ends itself (unloading what EveryAI loaded) when this app is gone, even after a crash.
          'LOCAL_PARENT_PID': '$pid',
          'HOST': '127.0.0.1',
          'PORT': '$port',
          'DATABASE_PATH': '$dir/everyai.db',
          'DEV_AUTH': 'true',
          // Signs nothing anyone sees (local mode has one user), but production mode wants one.
          'JWT_SECRET': _randomHex(32),
          'RATE_LIMIT_PER_MINUTE': '0',
        },
        // Only what we set: the user's shell variables (an OPENROUTER_API_KEY) must not leak in.
        includeParentEnvironment: false,
      );
    } on Object catch (e) {
      _apply(BackendStartFailed("The built-in server didn't start: $e"));
      return null;
    }
    if (_phase is! BackendStarting) {
      // Closed while it launched: it must not outlive the app.
      process.kill(ProcessSignal.sigkill);
      return null;
    }
    _process = process;
    await File('$dir/server.pid').writeAsString('${process.pid}');
    final log = File('$dir/server.log').openWrite(mode: FileMode.append);
    process.stdout.listen(log.add, onError: (_) {});
    process.stderr.listen(log.add, onError: (_) {});
    final info = LocalBackendInfo(baseUrl: Uri.parse('http://127.0.0.1:$port/'), token: token);
    unawaited(
      process.exitCode.then((code) async {
        await log.close().catchError((Object _) {});
        if (!identical(_process, process)) return;
        _process = null;
        _removePidFile(dir);
        final wasRunning = _phase is BackendRunning;
        if (!_apply(BackendExited('The built-in server stopped (exit $code); see $dir/server.log.'))) return;
        if (!wasRunning) return;
        // Restarted unless it keeps dying (3 times in a minute).
        final now = DateTime.now();
        _recentCrashes
          ..add(now)
          ..removeWhere((t) => now.difference(t) > const Duration(minutes: 1));
        if (_recentCrashes.length < 3) unawaited(ensureStarted());
      }),
    );
    if (!await _ready(info, process)) {
      if (identical(_process, process)) {
        _process = null;
        process.kill(ProcessSignal.sigkill);
      }
      _apply(BackendStartFailed("The built-in server didn't start; see $dir/server.log."));
      return null;
    }
    return _apply(BackendReady(info)) ? info : null;
  }

  Future<bool> _ready(LocalBackendInfo info, Process process) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    try {
      for (var i = 0; i < 100; i++) {
        if (!identical(_process, process) || _phase is! BackendStarting) return false;
        try {
          final req = await client.getUrl(info.baseUrl.resolve('v1/ping'));
          final res = await req.close();
          final body = await res.transform(utf8.decoder).join();
          if (res.statusCode == 200 && body.contains('everyai-backend')) return true;
        } on Object {
          // Not listening yet.
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      return false;
    } finally {
      client.close(force: true);
    }
  }

  static Future<int> _freePort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    return port;
  }

  /// A server left by a crashed app run would keep its port and database lock (and models loaded).
  static Future<void> _killOrphan(String dir) async {
    final f = File('$dir/server.pid');
    if (!f.existsSync()) return;
    final old = int.tryParse(f.readAsStringSync().trim());
    if (old != null && old > 0 && old != pid) Process.killPid(old);
    _removePidFile(dir);
  }

  static void _removePidFile(String dir) {
    try {
      File('$dir/server.pid').deleteSync();
    } on Object {
      // Gone already.
    }
  }

  @override
  Future<void> stop() async {
    final p = _process;
    if (!_apply(const BackendStopAsked())) return;
    if (p == null) {
      _apply(const BackendExited('Stopped.'));
      return;
    }
    await _end(p);
  }

  @override
  Future<void> close({Duration unloadWithin = const Duration(seconds: 4)}) async {
    final info = switch (_phase) {
      BackendRunning(:final info) => info,
      _ => null,
    };
    if (!_apply(const BackendCloseAsked())) return;
    final p = _process;
    if (p == null) return;
    // It unloads the models EveryAI loaded, then exits by itself.
    if (info != null) {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
      try {
        final req = await client.postUrl(info.baseUrl.resolve('v1/local/shutdown'));
        req.headers.set(LocalBackendInfo.tokenHeader, info.token);
        await (await req.close().timeout(unloadWithin)).drain<void>();
        // Replied: it is on its way out.
        await p.exitCode.timeout(const Duration(milliseconds: 500), onTimeout: () => -1);
      } on Object {
        // An older server without the route, or it hung: it is ended below.
      } finally {
        client.close(force: true);
      }
    }
    await _end(p, grace: const Duration(seconds: 1));
  }

  /// SIGTERM, then SIGKILL after [grace].
  Future<void> _end(Process p, {Duration grace = const Duration(seconds: 2)}) async {
    p.kill();
    await p.exitCode.timeout(
      grace,
      onTimeout: () {
        p.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    if (identical(_process, p)) _process = null;
    if (_dir case final d?) _removePidFile(d);
  }
}
