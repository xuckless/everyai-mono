// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../environments/env_processes.dart';
import '../environments/exec_env.dart';
import '../harness/session_processes.dart' show sessionEnvVar;
import 'driver.dart';
import 'driver_process_stub.dart' if (dart.library.io) 'driver_process_io.dart' as impl;
import 'json_rpc.dart';

/// A coding CLI the app runs for a session: stdout as lines (JSON-RPC or
/// ndjson), stdin as lines, stderr appended to the session's log.
abstract interface class DriverProcess implements LineChannel {
  int get pid;
  Future<int> get exitCode;
}

/// Starts [executable] (an absolute path, see [detectCli]) in [cwd], the
/// session's worktree, with the login shell's environment plus [env] and
/// `EVERYAI_SESSION` = [sessionTag], so Stop and the Processes pane own what
/// it runs. stderr goes to [logPath]. Closing it ends its whole process tree.
///
/// With an [execEnv] other than the host, [executable] and [cwd] are paths
/// inside it: the host runs the environment's bridge ([ExecEnv.wrap]) from
/// [logPath]'s folder, the tag goes inside too, and closing it (or its end)
/// also ends what still runs inside under that tag ([endInside]), since a
/// bridge's death doesn't reach the processes behind it.
Future<DriverProcess> spawnDriver({
  required String executable,
  required List<String> args,
  required String cwd,
  required String sessionTag,
  required String logPath,
  Map<String, String> env = const {},
  ExecEnv execEnv = HostEnv.instance,
}) async {
  if (execEnv.isHost) {
    return impl.spawnDriver(
      executable: executable,
      args: args,
      cwd: cwd,
      sessionTag: sessionTag,
      logPath: logPath,
      env: env,
    );
  }
  final w = execEnv.wrap(executable, args, cwd: cwd, env: {...env, sessionEnvVar: sessionTag});
  final cut = logPath.lastIndexOf(RegExp(r'[\\/]'));
  final process = await impl.spawnDriver(
    executable: w.executable,
    args: w.args,
    cwd: cut <= 0 ? logPath : logPath.substring(0, cut),
    sessionTag: sessionTag,
    logPath: logPath,
    env: w.environment,
  );
  return _InsideProcess(process, execEnv, sessionTag);
}

/// Ends what runs in [env] under a session's tag once its bridge is closed
/// or gone (tests replace it).
@visibleForTesting
Future<void> Function(ExecEnv env, String tag) endInsideOf = endInside;

/// A CLI behind an environment's bridge: the bridge process, plus an end of
/// the processes inside when it is closed or exits. Tracked for the app's
/// quit, which otherwise closes only the bridge.
final class _InsideProcess implements DriverProcess {
  _InsideProcess(this._bridge, this._env, this._tag) {
    trackDriverClose(close);
    unawaited(_bridge.exitCode.then((_) => _end(), onError: (Object _) => _end()));
  }

  final DriverProcess _bridge;
  final ExecEnv _env;
  final String _tag;
  Future<void>? _ended;

  Future<void> _end() => _ended ??= () async {
    untrackDriverClose(close);
    try {
      await endInsideOf(_env, _tag);
    } on Object {
      // Nothing left to end, or the environment is gone.
    }
  }();

  @override
  Stream<String> get lines => _bridge.lines;

  @override
  void send(String line) => _bridge.send(line);

  @override
  String get lastError => _bridge.lastError;

  @override
  int get pid => _bridge.pid;

  @override
  Future<int> get exitCode => _bridge.exitCode;

  @override
  Future<void> close() async {
    await _bridge.close();
    await _end();
  }
}

/// [spawnDriver] for a CLI that needs a terminal of its own (Grok Build
/// opens `/dev/tty` and exits without one): it runs under a pty, which is
/// its controlling terminal, while its stdin and stdout are named pipes in
/// [logPath]'s folder (`acp.in`, `acp.out`), so the JSON lines never pass
/// through the terminal (no echo, no line-length cap). What it writes to the
/// terminal goes to [logPath]. macOS and Linux only.
Future<DriverProcess> spawnDriverTty({
  required String executable,
  required List<String> args,
  required String cwd,
  required String sessionTag,
  required String logPath,
  Map<String, String> env = const {},
}) => impl.spawnDriverTty(
  executable: executable,
  args: args,
  cwd: cwd,
  sessionTag: sessionTag,
  logPath: logPath,
  env: env,
);

final _closers = <Future<void> Function()>{};

/// Registers [close] to run when the app quits (processes that don't come from [spawnDriver], e.g. a pty).
void trackDriverClose(Future<void> Function() close) => _closers.add(close);
void untrackDriverClose(Future<void> Function() close) => _closers.remove(close);

/// Ends every driver process still running (the app is quitting).
Future<void> closeAllDriverProcesses() =>
    Future.wait([impl.closeAllDriverProcesses(), for (final c in _closers.toList()) c()]);

/// Looks for [command] on the login shell's PATH plus the usual install
/// directories (an app started from the Dock doesn't have the user's; no
/// process runs for the lookup) and asks it for its version: installed,
/// path and the first line of `[command] [versionArgs]`, which is ended
/// after 4 s. Whether it is signed in is the driver's own check. [which]
/// replaces the lookup (tests).
Future<DriverStatus> detectCli(
  String command, {
  List<String> versionArgs = const ['--version'],
  Future<String?> Function(String command)? which,
}) => impl.detectCli(command, versionArgs: versionArgs, which: which);

/// Reads the login shell's PATH again, for the next [detectCli] and spawn
/// (the user installed something since the app started).
Future<void> reloadShellEnv() => impl.reloadShellEnv();

/// Reads the login shell's PATH if this app run hasn't yet (kept after).
Future<void> loadShellEnv() => impl.loadShellEnv();

/// The problem a driver whose sessions aren't built yet reports.
const notBuiltProblem = 'Not built yet.';

/// The problem a driver whose check ran out of time reports.
const noAnswerProblem = "Didn't answer in 30 s.";

/// [detectCli] for a driver whose sessions aren't built yet.
Future<DriverStatus> notBuiltYet(String command, {Future<String?> Function(String command)? which}) async =>
    (await detectCli(command, which: which)).withProblem(notBuiltProblem);
