// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_pty/flutter_pty.dart';

import '../../../core/process/supervisor.dart';
import '../panes/pty.dart' show ShellPty;

/// Starts [executable] in a pseudo-terminal for the agent's background shells, adopted by [supervisor] as
/// [owner]'s (its env must already carry `supervisor.tagsFor(owner)`). Null where the native library isn't there
/// (`flutter test`, a platform without ptys): the caller falls back to pipes. Throws [SupervisorClosed] once the
/// app quits (the pty is ended first).
typedef PtySpawner = Future<ShellPty?> Function(
  String executable,
  List<String> args,
  String cwd,
  Map<String, String> env,
  int rows,
  int cols, {
  required ProcessSupervisor supervisor,
  required ProcessOwner owner,
  String? label,
});

bool _unavailable = false;

Future<ShellPty?> spawnPty(
  String executable,
  List<String> args,
  String cwd,
  Map<String, String> env,
  int rows,
  int cols, {
  required ProcessSupervisor supervisor,
  required ProcessOwner owner,
  String? label,
}) async {
  if (_unavailable) return null;
  if (!(Platform.isMacOS || Platform.isLinux || Platform.isWindows)) return null;
  final Pty pty;
  try {
    pty = Pty.start(executable, arguments: args, workingDirectory: cwd, environment: env, rows: rows, columns: cols);
  } on Object catch (e) {
    // The library didn't load (tests) or the pty couldn't be made: pipes from now on.
    debugPrint('No pseudo-terminal ($e); background shells use pipes from now on.');
    _unavailable = true;
    return null;
  }
  final spec = SpawnSpec(owner: owner, kind: ProcessKind.shell, exe: executable, args: args, label: label);
  try {
    return _PtyShell(
      pty,
      supervisor.adopt(pty.pid, spec, exitCode: pty.exitCode, startedWithin: const Duration(seconds: 60)),
    );
  } on SupervisorClosed {
    // Started while the app quits: nothing would own it.
    pty.kill(ProcessSignal.sigkill);
    rethrow;
  }
}

final class _PtyShell implements ShellPty {
  _PtyShell(this._pty, this.child);
  final Pty _pty;
  @override
  final SupervisedChild child;

  @override
  int get pid => _pty.pid;
  @override
  Stream<Uint8List> get output => _pty.output;
  @override
  Future<int> get exitCode => _pty.exitCode;
  @override
  void write(Uint8List data) => _pty.write(data);
  @override
  void resize(int rows, int columns) => _pty.resize(rows, columns);

  /// The supervisor's verified stop (the shell's group and tree); the pty is never signalled after it, since its
  /// pid may then be another process's.
  @override
  Future<KillOutcome> kill() => child.stop();
}
