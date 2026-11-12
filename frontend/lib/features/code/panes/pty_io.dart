import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_pty/flutter_pty.dart';

import '../../../core/process/supervisor.dart';
import '../harness/everyai/git_bash.dart' show findGitBash;
import '../harness/everyai/shell_io.dart' show ShellEnv;
import '../harness/harness.dart' show HarnessError;
import '../harness/session_processes.dart' show sessionEnvVar;
import 'pty.dart';

bool get shellSupported => Platform.isMacOS || Platform.isLinux || Platform.isWindows;

ShellPty? startShell({
  required String workingDir,
  int rows = 24,
  int columns = 80,
  Map<String, String> env = const {},
  ProcessOwner? owner,
}) {
  if (!shellSupported) return null;
  final windows = Platform.isWindows;
  final shell = terminalShell(
    windows: windows,
    gitBash: windows ? findGitBash(Platform.environment, (f) => File(f).existsSync()) : null,
    shellVar: Platform.environment['SHELL'],
  );
  final who = owner ?? const AppOwner();
  final environment = {...Platform.environment, ...env, ...shell.env, ...supervisor.tagsFor(who)}
    // Not one of the agent's terminals: Stop (which matches the session tag) must leave these processes alone.
    ..remove(sessionEnvVar);
  final pty = Pty.start(
    shell.exe,
    arguments: shell.args,
    workingDirectory: Directory(workingDir).existsSync() ? workingDir : null,
    environment: environment,
    rows: rows,
    columns: columns,
  );
  return _adopt(pty, SpawnSpec(owner: who, kind: ProcessKind.pty, exe: shell.exe, args: shell.args, label: 'Terminal'));
}

/// The supervisor terminals belong to (tests swap in their own).
@visibleForTesting
ProcessSupervisor? debugPtySupervisor;

ProcessSupervisor get supervisor => debugPtySupervisor ?? ProcessSupervisor.instance;

/// [pty], adopted by the supervisor; ended at once (and null) when the app is quitting.
ShellPty? _adopt(Pty pty, SpawnSpec spec) {
  try {
    return _Pty(pty, supervisor.adopt(pty.pid, spec, exitCode: pty.exitCode));
  } on SupervisorClosed catch (e) {
    // Started while the app quits: it must not outlive it, and nothing will own it.
    debugPrint('${spec.label} (${pty.pid}) started while quitting ($e); ending it.');
    pty.kill(ProcessSignal.sigkill);
    return null;
  }
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
  final owner = SessionOwner(sessionTag);
  final pty = Pty.start(
    executable,
    arguments: args,
    workingDirectory: workingDir,
    environment: {...programEnv(shell.env, env, sessionTag), ...supervisor.tagsFor(owner)},
    rows: rows,
    columns: columns,
  );
  return _adopt(
    pty,
    SpawnSpec(owner: owner, kind: ProcessKind.pty, exe: executable, args: args, label: executable.split('/').last),
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
  _Pty(this._pty, this.child);
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

  /// The supervisor's verified stop of the program, its group and its tree (it knows when the program has exited,
  /// so a reused pid is never signalled). No SIGHUP from the pty afterwards: by then the pid may be another's.
  @override
  Future<KillOutcome> kill() => child.stop();
}

/// Where a terminal outside any session starts: the drive root on Windows (`C:\`), else the user's home folder.
String get terminalHomeDir => Platform.isWindows
    ? '${Platform.environment['SystemDrive'] ?? 'C:'}\\'
    : Platform.environment['HOME'] ?? Directory.current.path;
