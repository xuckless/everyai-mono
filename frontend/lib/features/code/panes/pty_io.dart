import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_pty/flutter_pty.dart';

import '../harness/everyai/git_bash.dart' show findGitBash;
import '../harness/everyai/shell_io.dart' show ShellEnv, killTree;
import '../harness/harness.dart' show HarnessError;
import '../harness/session_processes.dart' show sessionEnvVar;
import 'pty.dart';

bool get shellSupported => Platform.isMacOS || Platform.isLinux || Platform.isWindows;

ShellPty? startShell({
  required String workingDir,
  int rows = 24,
  int columns = 80,
  Map<String, String> env = const {},
}) {
  if (!shellSupported) return null;
  final windows = Platform.isWindows;
  final shell = terminalShell(
    windows: windows,
    gitBash: windows ? findGitBash(Platform.environment, (f) => File(f).existsSync()) : null,
    shellVar: Platform.environment['SHELL'],
  );
  final environment = {...Platform.environment, ...env, ...shell.env}
    // Not one of the agent's terminals: Stop must leave these processes alone.
    ..remove(sessionEnvVar);
  return _Pty(
    Pty.start(
      shell.exe,
      arguments: shell.args,
      workingDirectory: Directory(workingDir).existsSync() ? workingDir : null,
      environment: environment,
      rows: rows,
      columns: columns,
    ),
  );
}

Future<ShellPty?> startProgram({
  required String executable,
  required List<String> args,
  required String workingDir,
  required String sessionTag,
  int rows = 24,
  int columns = 80,
  Map<String, String> env = const {},
}) async {
  if (!shellSupported) return null;
  // No fallback folder: a coding CLI must not run (and edit files) wherever the app happens to be.
  if (!Directory(workingDir).existsSync()) throw HarnessError("The session's folder is missing.");
  final shell = await ShellEnv.load();
  return _Pty(
    Pty.start(
      executable,
      arguments: args,
      workingDirectory: workingDir,
      environment: programEnv(shell.env, env, sessionTag),
      rows: rows,
      columns: columns,
    ),
  );
}

/// The user's shell as a login shell, so their profile sets PATH (an app
/// started from the Dock has a minimal one), and what to add to its env. On
/// Windows: Git Bash ([gitBash]) staying in the pane's folder
/// (`CHERE_INVOKING`), else PowerShell. Elsewhere [shellVar] (`$SHELL`) when
/// [exists], else zsh on macOS and bash on Linux.
@visibleForTesting
({String exe, List<String> args, Map<String, String> env}) terminalShell({
  required bool windows,
  String? gitBash,
  String? shellVar,
  bool Function(String file)? exists,
  bool? macOS,
}) {
  const term = {'TERM': 'xterm-256color'};
  if (windows) {
    if (gitBash != null) return (exe: gitBash, args: const ['--login', '-i'], env: {...term, 'CHERE_INVOKING': '1'});
    return (exe: 'powershell.exe', args: const ['-NoLogo'], env: const {});
  }
  final has = exists ?? (f) => File(f).existsSync();
  if (shellVar != null && shellVar.isNotEmpty && has(shellVar)) return (exe: shellVar, args: const ['-l'], env: term);
  return (exe: (macOS ?? Platform.isMacOS) ? '/bin/zsh' : '/bin/bash', args: const ['-l'], env: term);
}

final class _Pty implements ShellPty {
  _Pty(this._pty) {
    unawaited(_pty.exitCode.then((_) => _exited = true));
  }
  final Pty _pty;
  var _exited = false;

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
  void kill() {
    // The whole tree, not only the CLI: what it started may have left its
    // process group. Not once it has exited: its pid may be reused.
    if (!_exited) unawaited(killTree(pid));
    _pty.kill(ProcessSignal.sighup);
  }
}

/// Where a terminal outside any session starts: the drive root on Windows (`C:\`), else the user's home folder.
String get terminalHomeDir => Platform.isWindows
    ? '${Platform.environment['SystemDrive'] ?? 'C:'}\\'
    : Platform.environment['HOME'] ?? Directory.current.path;
