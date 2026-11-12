// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_pty/flutter_pty.dart';

import '../../../core/process/supervisor.dart';
import '../harness/everyai/shell_io.dart' show ShellEnv;
import '../harness/harness.dart' show HarnessError;
import '../harness/session_processes.dart' show registerDriverRoot, sessionEnvVar, unregisterDriverRoot;
import 'driver.dart';
import 'detection/cli_scan.dart' show findCli;
import 'driver_process.dart';
import 'json_rpc.dart' show EndsInput;
import 'short_run.dart';

Future<DriverProcess> spawnDriver({
  required String executable,
  required List<String> args,
  required String cwd,
  required String sessionTag,
  required String logPath,
  Map<String, String> env = const {},
  bool closeInputFirst = true,
}) async {
  final shell = await ShellEnv.load();
  // Before the start: it is the working directory of an environment's bridge.
  File(logPath).parent.createSync(recursive: true);
  // In the root zone: the supervisor's timers for it are real time even when the caller's aren't (widget tests).
  final child = await Zone.root.run(
    () => ProcessSupervisor.instance.spawn(
      SpawnSpec(
        owner: driverOwner(sessionTag),
        kind: ProcessKind.leadCli,
        exe: executable,
        args: args,
        env: {...shell.env, ...env, sessionEnvVar: sessionTag},
        cwd: cwd,
        label: 'Driver ${_name(executable)}',
        detail: sessionTag,
        // A CLI on stdio ends by itself when its input closes (claude -p, codex app-server, ACP agents).
        politeStop: closeInputFirst ? _closeInput : null,
      ),
    ),
  );
  registerDriverRoot(sessionTag, child.pid!);
  return _Process(child, sessionTag, File(logPath).openWrite(mode: FileMode.append));
}

const _closeInput = PoliteStop(_endInput, grace: Duration(milliseconds: 500));

Future<void> _endInput(SupervisedChild child) async {
  if (child is SupervisedProcess) {
    try {
      await child.stdin.close();
    } on Object catch (e) {
      // Its stdin is gone with it: the stop goes on to SIGTERM.
      debugPrint('EveryAI processes: closing ${child.spec.label}\'s input failed ($e); it is stopped by signal.');
    }
  }
}

String _name(String executable) => executable.substring(executable.lastIndexOf(RegExp(r'[\\/]')) + 1);

/// A program started under a terminal: its pid, exit code and what it
/// wrote to the terminal.
typedef TtyProgram = ({int pid, Future<int> exitCode, Stream<List<int>> output});

/// Starts [executable] [args] in [cwd] with [env] (exactly) under a pty;
/// tests start it with plain pipes.
typedef TtyStart = Future<TtyProgram> Function(
  String executable,
  List<String> args,
  String cwd,
  Map<String, String> env,
);

Future<TtyProgram> _ptyStart(String executable, List<String> args, String cwd, Map<String, String> env) async {
  final pty = Pty.start(executable, arguments: args, workingDirectory: cwd, environment: env);
  return (pid: pty.pid, exitCode: pty.exitCode, output: pty.output);
}

/// The shell line that runs the CLI ("$0" "$@") on the pipes named in the
/// environment, its stderr appended to the log. `exec` keeps the pty's
/// session and terminal for the CLI itself.
const _onPipes = r'exec "$0" "$@" <"$EVERYAI_ACP_IN" >"$EVERYAI_ACP_OUT" 2>>"$EVERYAI_ACP_LOG"';

Future<DriverProcess> spawnDriverTty({
  required String executable,
  required List<String> args,
  required String cwd,
  required String sessionTag,
  required String logPath,
  Map<String, String> env = const {},
  TtyStart start = _ptyStart,
}) async {
  // Not reached on Windows: the only caller is the ACP fallback for a CLI that
  // fails opening /dev/tty (Grok's ENXIO), which Windows doesn't have. The
  // pipes below (mkfifo, /bin/sh) have no cheap Windows equivalent, and
  // ConPTY rewrites output, so JSON can't go over the terminal itself.
  if (Platform.isWindows) {
    throw const HarnessError("This agent needs a terminal, which the app can't give it on Windows.");
  }
  final dir = File(logPath).parent..createSync(recursive: true);
  final input = '${dir.path}/acp.in';
  final output = '${dir.path}/acp.out';
  // Left behind by a crash: made again.
  for (final f in [input, output]) {
    if (FileSystemEntity.typeSync(f, followLinks: false) != FileSystemEntityType.notFound) File(f).deleteSync();
  }
  final made = await runShort(
    'mkfifo',
    [input, output],
    timeout: const Duration(seconds: 10),
    owner: driverOwner(sessionTag),
  );
  if (runProblem('mkfifo', made) case final why?) throw HarnessError("Couldn't make the pipes for the agent: $why");
  final shell = await ShellEnv.load();
  final supervisor = ProcessSupervisor.instance;
  final owner = driverOwner(sessionTag);
  // Only what this run writes counts as its last words.
  final logStart = _length(logPath);
  final TtyProgram program;
  try {
    program = await start(
      '/bin/sh',
      ['-c', _onPipes, executable, ...args],
      cwd,
      {
        ...shell.env,
        ...env,
        sessionEnvVar: sessionTag,
        // flutter_pty starts it, so the supervisor adopts it: it carries the tags a spawn would give it.
        ...supervisor.tagsFor(owner),
        'EVERYAI_ACP_IN': input,
        'EVERYAI_ACP_OUT': output,
        'EVERYAI_ACP_LOG': logPath,
      },
    );
  } on Object {
    _removePipes(input, output);
    rethrow;
  }
  final SupervisedChild child;
  try {
    child = supervisor.adopt(
      program.pid,
      SpawnSpec(
        owner: owner,
        kind: ProcessKind.leadCli,
        exe: executable,
        args: args,
        label: 'Driver ${_name(executable)} (terminal)',
        detail: sessionTag,
      ),
      exitCode: program.exitCode,
    );
  } on SupervisorClosed {
    // Started while the app quits: it must not outlive it.
    logStop('Driver ${_name(executable)} (terminal)', await supervisor.killTree(program.pid));
    _removePipes(input, output);
    rethrow;
  }
  registerDriverRoot(sessionTag, program.pid);
  return _TtyProcess(program, child, sessionTag, logPath, logStart, input, output);
}

int _length(String path) {
  try {
    return File(path).lengthSync();
  } on FileSystemException {
    return 0;
  }
}

void _removePipes(String input, String output) {
  for (final f in [input, output]) {
    try {
      File(f).deleteSync();
    } on FileSystemException {
      // Already gone.
    }
  }
}

/// A CLI under a pty with its JSON on named pipes ([spawnDriverTty]).
/// Both ends are opened at once; an open waits for the other side on Dart's
/// IO threads, so the UI never blocks. When the CLI is gone, each pipe is
/// held open read-write (which never waits) until our own open is through,
/// so nothing waits on a CLI that never opened its side.
///
/// Its process is the supervisor's (adopted): [close] stops it there, verified, before the pipes and the terminal
/// are let go (a SIGHUP from closing the terminal first raced the stop and orphaned what the CLI started).
final class _TtyProcess implements DriverProcess {
  _TtyProcess(this._program, this._child, this._tag, this._logPath, this._logStart, this._input, this._output) {
    // Whatever it writes to the terminal, so a full pty buffer can't stall it.
    // Its own file: sh appends the CLI's stderr to the log, which a second
    // writer without O_APPEND would overwrite.
    _tty = File('${File(_logPath).parent.path}/tty.log').openWrite();
    _ttyOutput = _program.output.listen((d) {
      if (!_released) _tty.add(d);
    }, onError: (Object _) {});
    _reader = File(_output).open();
    // Write-only, so a write after the CLI is gone fails instead of filling the pipe.
    _writer = File(_input).open(mode: FileMode.writeOnly);
    for (final f in [_reader, _writer]) {
      unawaited(f.then((_) {}, onError: (Object _) {}));
    }
    trackDriverClose(close);
    unawaited(
      _program.exitCode.then((_) async {
        unregisterDriverRoot(_tag, pid);
        await _unblock();
        await _release();
      }),
    );
  }

  final TtyProgram _program;
  final SupervisedChild _child;
  final String _tag;
  final String _logPath;
  final String _input;
  final String _output;
  final int _logStart;
  late final IOSink _tty;
  late final StreamSubscription<List<int>> _ttyOutput;
  late final Future<RandomAccessFile> _reader;
  late final Future<RandomAccessFile> _writer;
  Future<void> _writes = Future.value();
  Future<void>? _unblocking;
  Future<void>? _releasing;
  var _released = false;

  /// The close, once asked (a second close joins it).
  Future<KillOutcome>? _closing;

  /// Lines may still be sent: not closed, and its process hasn't been seen to end.
  bool get _open => _closing == null && _child.state.live;

  @override
  late final Stream<String> lines = _read()
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .asBroadcastStream();

  Stream<List<int>> _read() async* {
    final f = await _reader;
    try {
      while (true) {
        final block = await f.read(65536);
        if (block.isEmpty) break;
        yield block;
      }
    } finally {
      await f.close();
    }
  }

  @override
  int get pid => _program.pid;

  @override
  Future<int> get exitCode => _program.exitCode;

  /// The end of what the CLI wrote to stderr in this run (the log holds
  /// earlier runs too).
  @override
  String get lastError {
    try {
      final f = File(_logPath).openSync();
      try {
        final end = f.lengthSync();
        final from = end - 2000 > _logStart ? end - 2000 : _logStart;
        if (end <= from) return '';
        f.setPositionSync(from);
        return utf8.decode(f.readSync(end - from), allowMalformed: true);
      } finally {
        f.closeSync();
      }
    } on FileSystemException {
      return '';
    }
  }

  @override
  void send(String line) {
    if (!_open) return;
    _writes = _writes.then((_) async {
      try {
        await (await _writer).writeString('$line\n');
      } on Object {
        // The CLI is gone; nothing reads the pipe.
      }
    });
  }

  /// Holds each pipe open read-write until our own open of it is through;
  /// once, as an open after [_release] removed the pipes would make files.
  Future<void> _unblock() => _unblocking ??= () async {
    for (final (path, ours) in [(_output, _reader), (_input, _writer)]) {
      try {
        final hold = await File(path).open(mode: FileMode.write);
        await ours.then((_) {}, onError: (Object _) {});
        await hold.close();
      } on FileSystemException {
        // Removed already.
      }
    }
  }();

  /// Lets go of the pipes and the terminal's log, once: when the CLI exits
  /// or the session closes, whichever is first.
  Future<void> _release() => _releasing ??= () async {
    await _writes;
    try {
      await (await _writer).close();
    } on Object {
      // Never opened, or closed already.
    }
    _released = true;
    await _ttyOutput.cancel();
    await _tty.flush();
    await _tty.close();
    _removePipes(_input, _output);
  }();

  /// Stops the CLI and what it started (verified; a CLI that already exited is checked by its start time, never
  /// signalled by its pid alone), then lets go of the pipes.
  @override
  Future<KillOutcome> close() => _closing ??= () async {
    untrackDriverClose(close);
    unregisterDriverRoot(_tag, pid);
    final outcome = await stopChecked(_child.spec.label, _child.stop);
    await _unblock();
    await _release();
    return outcome;
  }();
}

final class _Process implements DriverProcess, EndsInput {
  _Process(this._child, this._tag, this._log) {
    _child.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen((s) {
      _log.write(s);
      _tail.write(s);
      if (_tail.length > 4000) {
        final keep = _tail.toString().substring(_tail.length - 2000);
        _tail
          ..clear()
          ..write(keep);
      }
    }, onDone: () => unawaited(_log.close()));
    // A write after the CLI died fails on the pipe; nobody else listens.
    unawaited(_child.stdin.done.then((_) {}, onError: (Object _) {}));
    unawaited(_child.exitCode.then((_) => unregisterDriverRoot(_tag, pid)));
  }

  final SupervisedProcess _child;
  final String _tag;
  final IOSink _log;
  final _tail = StringBuffer();

  /// The close, once asked (a second close joins it).
  Future<KillOutcome>? _closing;

  /// Lines may still be sent: not closed, and its process hasn't been seen to end.
  bool get _open => _closing == null && _child.state.live;

  @override
  late final Stream<String> lines = _child.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .asBroadcastStream();

  @override
  int get pid => _child.pid!;

  @override
  Future<int> get exitCode => _child.exitCode;

  @override
  String get lastError => _tail.toString();

  @override
  void send(String line) {
    if (_open) _child.stdin.writeln(line);
  }

  @override
  void endInput() {
    if (_open) unawaited(_child.stdin.close().then((_) {}, onError: (Object _) {}));
  }

  /// The supervisor's verified stop of the CLI and what it started (its input closed first; one that exited
  /// already is checked by start time, never signalled by pid alone).
  @override
  Future<KillOutcome> close() => _closing ??= () async {
    unregisterDriverRoot(_tag, pid);
    return stopChecked(_child.spec.label, _child.stop);
  }();
}

/// Each `[command] --version` check runs once at a time (a second asker gets the same answer).
final _versionChecks = SingleFlight<String, DriverStatus>();

/// Every coding CLI the supervisor lists, stopped (verified).
Future<KillOutcome> closeAllDriverProcesses() async => KillOutcome.merge(
  await Future.wait([
    for (final c in ProcessSupervisor.instance.children)
      if (c.spec.kind == ProcessKind.leadCli) stopChecked(c.spec.label, c.stop),
  ]),
);

Future<DriverStatus> detectCli(
  String command, {
  List<String> versionArgs = const ['--version'],
  Future<String?> Function(String command)? which,
}) async {
  final path = await (which ?? findCli)(command);
  if (path == null) return const DriverStatus();
  return _versionChecks.run('$path\x00${versionArgs.join('\x00')}', () => _version(command, path, versionArgs));
}

Future<DriverStatus> _version(String command, String path, List<String> versionArgs) async {
  final ShellEnv shell;
  try {
    shell = await ShellEnv.load();
  } on Object catch (e) {
    return DriverStatus(installed: true, path: path, problem: "Couldn't run $command: $e");
  }
  // A CLI that waits on a prompt (an update offer) is stopped when the time runs out, with what it started.
  final r = await runShort(
    path,
    versionArgs,
    timeout: versionTimeout,
    env: shell.env,
    owner: ProbeOwner('version-$command'),
  );
  return switch (r) {
    Finished(:final stdout) => DriverStatus(
      installed: true,
      path: path,
      version: switch (stdout.trim().split('\n').first.trim()) {
        '' => null,
        final first => first,
      },
    ),
    TimedOut(:final kill) => DriverStatus(
      installed: true,
      path: path,
      problem:
          "$command didn't say its version.${logStop('$command --version', kill) is Ended ? '' : ' (still running?)'}",
    ),
    Cancelled() => DriverStatus(installed: true, path: path, problem: "$command's check was cancelled."),
    StartFailed(:final error) => DriverStatus(installed: true, path: path, problem: "Couldn't run $command: $error"),
  };
}

/// How long `--version` may take before the check gives up on it.
const versionTimeout = Duration(seconds: 4);

Future<void> reloadShellEnv() => ShellEnv.reload();

Future<void> loadShellEnv() => ShellEnv.load();

/// The first file named [command] in the directories of [path] (or
/// [command] itself when it is a path), without starting a process. On
/// Windows each [pathExt] extension is tried too. [isFile] tells a file
/// that can run from a directory or a missing one (tests).
String? findOnPath(String command, String path, {bool? windows, String? pathExt, bool Function(String path)? isFile}) {
  final win = windows ?? Platform.isWindows;
  final runs = isFile ?? (win ? (p) => File(p).existsSync() : _isExecutable);
  final sep = win ? '\\' : '/';
  // cmd.exe runs `claude.cmd`, never npm's extensionless shell shim beside it.
  final bare = win && RegExp(r'\.[A-Za-z0-9]{1,4}$').hasMatch(command);
  final exts = win
      ? [
          if (bare) '',
          ...(pathExt ?? Platform.environment['PATHEXT'] ?? '.COM;.EXE;.BAT;.CMD')
              .split(';')
              .where((e) => e.isNotEmpty),
        ]
      : const [''];
  final named = command.contains('/') || (win && command.contains('\\'));
  final dirs = named ? const [''] : path.split(win ? ';' : ':').where((d) => d.isNotEmpty);
  for (final dir in dirs) {
    for (final ext in exts) {
      final candidate = named ? '$command$ext' : '${dir.endsWith(sep) ? dir : '$dir$sep'}$command$ext';
      if (runs(candidate)) return candidate;
    }
  }
  return null;
}

bool _isExecutable(String path) {
  final stat = FileStat.statSync(path);
  return stat.type == FileSystemEntityType.file && stat.mode & 0x49 != 0;
}
