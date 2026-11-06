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

  Process? _process;
  LocalBackendInfo? _info;
  Future<LocalBackendInfo?>? _starting;
  String? _problem;
  bool _stopped = false;
  final _recentCrashes = <DateTime>[];

  @override
  String? get problem => _problem;

  @override
  bool get running => _info != null && _process != null;

  @override
  Future<LocalBackendInfo?> ensureStarted() {
    if (_info != null && _process != null) return Future.value(_info);
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  Future<LocalBackendInfo?> _start() async {
    _stopped = false;
    final bin = binary ?? findLocalBackend();
    if (bin == null) {
      _problem = "This build doesn't include the built-in server.";
      return null;
    }
    final dir = dataDir ?? '${(await getApplicationSupportDirectory()).path}/local-backend';
    await Directory(dir).create(recursive: true);
    await _killOrphan(dir);
    final port = await _freePort();
    final token = _randomHex(24);
    final process = await Process.start(
      bin,
      const [],
      workingDirectory: dir,
      environment: {
        'ANOLE_ENV': 'production',
        'LOCAL_MODE': 'true',
        'LOCAL_TOKEN': token,
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
        _info = null;
        if (_stopped) return;
        _problem = 'The built-in server stopped (exit $code); see $dir/server.log.';
        // Restart unless it keeps dying (3 times in a minute).
        final now = DateTime.now();
        _recentCrashes
          ..add(now)
          ..removeWhere((t) => now.difference(t) > const Duration(minutes: 1));
        if (_recentCrashes.length < 3) unawaited(ensureStarted());
      }),
    );
    if (!await _ready(info)) {
      _problem = "The built-in server didn't start; see $dir/server.log.";
      process.kill();
      _process = null;
      return null;
    }
    _problem = null;
    return _info = info;
  }

  Future<bool> _ready(LocalBackendInfo info) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    try {
      for (var i = 0; i < 100; i++) {
        if (_process == null) return false;
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

  /// A server left by a crashed app run would keep its port and database lock.
  static Future<void> _killOrphan(String dir) async {
    final f = File('$dir/server.pid');
    if (!f.existsSync()) return;
    final pid = int.tryParse(f.readAsStringSync().trim());
    if (pid != null && pid > 0) Process.killPid(pid);
    try {
      f.deleteSync();
    } on Object {
      // Gone already.
    }
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    final p = _process;
    _process = null;
    _info = null;
    if (p == null) return;
    p.kill();
    await p.exitCode.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        p.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
  }
}
