// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_pty/flutter_pty.dart';

import '../panes/pty.dart' show ShellPty;

/// Starts [executable] in a pseudo-terminal, for the agent's background
/// shells. Null where the native library isn't there (`flutter test`, a
/// platform without ptys): the caller falls back to pipes.
typedef PtySpawner = Future<ShellPty?> Function(
  String executable,
  List<String> args,
  String cwd,
  Map<String, String> env,
  int rows,
  int cols,
);

bool _unavailable = false;

Future<ShellPty?> spawnPty(
  String executable,
  List<String> args,
  String cwd,
  Map<String, String> env,
  int rows,
  int cols,
) async {
  if (_unavailable) return null;
  if (!(Platform.isMacOS || Platform.isLinux || Platform.isWindows)) return null;
  try {
    return _PtyShell(
      Pty.start(executable, arguments: args, workingDirectory: cwd, environment: env, rows: rows, columns: cols),
    );
  } on Object {
    // The library didn't load (tests) or the pty couldn't be made: pipes from now on.
    _unavailable = true;
    return null;
  }
}

final class _PtyShell implements ShellPty {
  _PtyShell(this._pty);
  final Pty _pty;

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
  @override
  void kill() => _pty.kill(ProcessSignal.sighup);
}
