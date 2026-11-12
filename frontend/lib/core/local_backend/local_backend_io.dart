// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

import '../process/supervisor.dart';
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

/// The bundled server's process, as one of the process supervisor's children: its own process group, in the ledger
/// (a crashed run's server is ended by the next launch's sweep), stopped with a verified kill after a polite
/// `POST /v1/local/shutdown`. Which run's server holds the data folder is kept in `server.owner.json` (the app's
/// tag, the server's pid and start time), so a second running EveryAI is refused instead of killed, and a bare pid
/// is never signalled.
final class IoLocalBackend implements LocalBackend {
  IoLocalBackend({this.binary, this.dataDir, ProcessSupervisor? supervisor})
    : _supervisor = supervisor; // ignore: prefer_initializing_formals

  /// Overrides for tests.
  final String? binary;
  final String? dataDir;
  final ProcessSupervisor? _supervisor;
  ProcessSupervisor get _sup => _supervisor ?? ProcessSupervisor.instance;

  BackendPhase _phase = const BackendIdle();
  SupervisedProcess? _child;
  String? _dir;
  Future<LocalBackendInfo?>? _starting;
  Future<KillOutcome>? _stopping;
  final _recentCrashes = <DateTime>[];

  @override
  BackendPhase get phase => _phase;

  @override
  String? get problem => switch (_phase) {
    BackendUnavailable(:final reason) || BackendCrashed(:final reason) || BackendBlocked(:final reason) => reason,
    BackendNotClosed(:final reason) => 'The built-in server did not close: $reason',
    BackendClosed() => 'EveryAI is quitting.',
    _ => null,
  };

  @override
  bool get running => _phase is BackendRunning;

  bool _apply(BackendEvent e) {
    final next = applyBackendEvent(_phase, e);
    if (next == null) return false;
    _phase = next;
    return true;
  }

  @override
  Future<LocalBackendInfo?> ensureStarted() {
    if (_phase case BackendRunning(:final info)) return Future.value(info);
    if (_starting case final s?) return s;
    if (nextBackendPhase(_phase, const BackendStartAsked()) == null) return Future.value(null);
    _apply(const BackendStartAsked());
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
    final held = await _claimDataDir(dir);
    if (_phase is! BackendStarting) return null; // Closed or stopped meanwhile.
    if (held != null) {
      _apply(BackendHeldElsewhere(held));
      return null;
    }
    final port = await _freePort();
    final token = _randomHex(24);
    final info = LocalBackendInfo(baseUrl: Uri.parse('http://127.0.0.1:$port/'), token: token);
    final SupervisedProcess child;
    try {
      child = await _sup.spawn(
        SpawnSpec(
          owner: const AppOwner(),
          kind: ProcessKind.backend,
          exe: bin,
          cwd: dir,
          label: 'bundled server',
          port: port,
          detail: dir,
          // It unloads the models EveryAI loaded, then exits by itself; SIGTERM follows if it doesn't.
          politeStop: PoliteStop((_) => _askShutdown(info, const Duration(milliseconds: 2500)), grace: _politeGrace),
          env: {
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
        ),
      );
    } on Object catch (e) {
      if (_phase is BackendStarting) _apply(BackendStartFailed("The built-in server didn't start: $e"));
      return null;
    }
    _child = child;
    final log = File('$dir/server.log').openWrite(mode: FileMode.append);
    void lost(Object e) => debugPrint('Bundled server: reading its output failed: $e');
    final outDone = child.stdout.listen(log.add).asFuture<void>().catchError(lost);
    final errDone = child.stderr.listen(log.add).asFuture<void>().catchError(lost);
    unawaited(_recordOwner(dir, child));
    unawaited(
      child.exitCode.then((code) async {
        await Future.wait([outDone, errDone]).timeout(const Duration(seconds: 1), onTimeout: () => const []);
        try {
          await log.close();
        } on Object catch (e) {
          debugPrint('Bundled server: server.log could not be closed: $e');
        }
        if (!identical(_child, child)) return;
        // A stop under way settles the phase with its own (verified) outcome.
        if (_stopping != null || _phase is BackendClosed || _phase is BackendStopping) return;
        _child = null;
        _forgetOwner(dir, child.pid);
        final wasRunning = _phase is BackendRunning;
        _apply(BackendExited('The built-in server stopped (exit $code); see $dir/server.log.'));
        if (!wasRunning) return;
        // What it may have left behind ends before a restart (its database and port must be free).
        final left = await child.stop();
        if (left is! Ended) {
          debugPrint('NOT CLOSED: the bundled server crashed and left $left; it is not restarted.');
          return;
        }
        // Restarted unless it keeps dying (3 times in a minute).
        final now = DateTime.now();
        _recentCrashes
          ..add(now)
          ..removeWhere((t) => now.difference(t) > const Duration(minutes: 1));
        if (_recentCrashes.length < 3) unawaited(ensureStarted());
      }),
    );
    if (!await _ready(info, child)) {
      if (identical(_child, child) && _phase is BackendStarting) {
        _child = null;
        final outcome = await child.stop();
        _forgetOwner(dir, child.pid);
        final left = outcome is Ended ? '' : ' It did not close: $outcome.';
        if (_phase is BackendStarting) {
          _apply(BackendStartFailed("The built-in server didn't start; see $dir/server.log.$left"));
        }
      }
      return null;
    }
    if (_phase is! BackendStarting) return null;
    return _apply(BackendReady(info)) ? info : null;
  }

  static const _politeGrace = Duration(seconds: 3);

  Future<bool> _ready(LocalBackendInfo info, SupervisedProcess child) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    try {
      for (var i = 0; i < 100; i++) {
        if (!identical(_child, child) || _phase is! BackendStarting || !child.state.live) return false;
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

  static const _ownerFile = 'server.owner.json';

  /// Writes which run's server holds [dir] (once its start time is known).
  Future<void> _recordOwner(String dir, SupervisedProcess child) async {
    final String start;
    try {
      start = (await child.landed).start;
    } on Object {
      return; // Ended before it was read: nothing holds the folder.
    }
    if (!identical(_child, child)) return;
    try {
      await File('$dir/$_ownerFile').writeAsString(jsonEncode({'app': _sup.appTag, 'pid': child.pid, 'start': start}));
    } on FileSystemException catch (e) {
      debugPrint('Bundled server: $dir/$_ownerFile could not be written ($e); a second EveryAI could not tell.');
    }
  }

  void _forgetOwner(String dir, int? serverPid) {
    final f = File('$dir/$_ownerFile');
    try {
      if (!f.existsSync()) return;
      final j = jsonDecode(f.readAsStringSync());
      if (j is Map && j['pid'] == serverPid && j['app'] == _sup.appTag) f.deleteSync();
    } on Object catch (e) {
      debugPrint('Bundled server: $dir/$_ownerFile could not be cleared: $e');
    }
  }

  /// Null when this run may start a server on [dir]; else why not. A server another running EveryAI started is
  /// never touched. One left by a run that ended without quitting is the launch sweep's (by its ledger), waited for
  /// here; this run's own (a hot restart) is stopped through the supervisor.
  Future<String?> _claimDataDir(String dir) async {
    final f = File('$dir/$_ownerFile');
    if (!f.existsSync()) return null;
    final ({String app, int pid, String start}) owner;
    try {
      final j = jsonDecode(await f.readAsString());
      if (j case {'app': final String app, 'pid': final int p, 'start': final String start}) {
        owner = (app: app, pid: p, start: start);
      } else {
        throw const FormatException('not an owner record');
      }
    } on Object catch (e) {
      debugPrint('Bundled server: $dir/$_ownerFile is unreadable ($e); it is replaced.');
      await f.delete();
      return null;
    }
    Future<ProcessList?> table() async => switch (await _sup.scan()) {
      Listed(:final table) => table,
      ScanFailed() => null,
    };
    var t = await table();
    if (t == null) return "Couldn't check whether another EveryAI uses the built-in server's data in $dir.";
    if (!t.aliveAt(owner.pid, owner.start)) {
      await f.delete();
      return null;
    }
    if (owner.app == _sup.appTag) {
      // This run's own (a hot restart lost track of it): the supervisor took it back from its ledger.
      final c = _sup.byPid(owner.pid);
      final outcome = c == null ? const ScanFailed('not in the process list') : await c.stop();
      if (outcome is Ended) {
        await f.delete();
        return null;
      }
      return 'The built-in server this run started before (pid ${owner.pid}) did not close: $outcome.';
    }
    final app = parseAppTag(owner.app);
    if (app != null && t.aliveAt(app.pid, app.start)) {
      return 'Another EveryAI (pid ${app.pid}) runs the built-in server on this data folder ($dir). Quit it to use '
          'local models and your own keys here.';
    }
    // Its app is gone: the launch sweep ends what that run's ledger lists.
    await _sup.sweepPreviousRuns();
    t = await table();
    if (t != null && !t.aliveAt(owner.pid, owner.start)) {
      await f.delete();
      return null;
    }
    return 'A built-in server left by an EveryAI that ended without quitting still runs (pid ${owner.pid}) and '
        "couldn't be ended; it holds $dir.";
  }

  /// Asks the server to unload what EveryAI loaded and exit; throws when it doesn't answer within [within].
  static Future<void> _askShutdown(LocalBackendInfo info, Duration within) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    try {
      final req = await client.postUrl(info.baseUrl.resolve('v1/local/shutdown')).timeout(within);
      req.headers.set(LocalBackendInfo.tokenHeader, info.token);
      await (await req.close().timeout(within)).drain<void>();
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<KillOutcome> stop() {
    if (_stopping case final s?) return s;
    if (nextBackendPhase(_phase, const BackendStopAsked()) == null) return Future.value(const Ended([]));
    _apply(const BackendStopAsked());
    final f = _stopNow();
    _stopping = f;
    return f.whenComplete(() => _stopping = null);
  }

  Future<KillOutcome> _stopNow() async {
    // A start under way lands first (its child is then ended here).
    await _starting;
    final c = _child;
    final outcome = c == null ? const Ended(<int>[]) : await c.stop();
    if (outcome is Ended) {
      if (identical(_child, c)) _child = null;
      if (_dir case final d?) _forgetOwner(d, c?.pid);
      if (_phase is BackendStopping) _apply(const BackendExited('Stopped.'));
    } else {
      debugPrint('NOT CLOSED: the bundled server: $outcome');
      if (_phase is BackendStopping) _apply(BackendStopNotClosed(outcome));
    }
    return outcome;
  }

  @override
  Future<KillOutcome> close({Duration unloadWithin = const Duration(seconds: 4)}) async {
    final info = switch (_phase) {
      BackendRunning(:final info) => info,
      _ => null,
    };
    if (_phase is! BackendClosed) _apply(const BackendCloseAsked());
    final running = _stopping;
    if (running != null) return running;
    await _starting;
    final c = _child;
    if (c == null) return const Ended([]);
    // It unloads the models EveryAI loaded, then exits by itself.
    if (info != null) {
      try {
        await _askShutdown(info, unloadWithin);
        await c.ended.timeout(const Duration(milliseconds: 500), onTimeout: () => const SeenGone());
      } on Object catch (e) {
        debugPrint('Bundled server: it did not take the shutdown request ($e); it is stopped.');
      }
    }
    final outcome = await c.stop(timings: StopTimings.quit);
    if (outcome is Ended) {
      _child = null;
      if (_dir case final d?) _forgetOwner(d, c.pid);
    } else {
      debugPrint('NOT CLOSED: the bundled server at quit: $outcome');
    }
    return outcome;
  }
}
