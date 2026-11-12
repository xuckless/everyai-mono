import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../../../core/process/pty_spawn_io.dart';
import '../../../core/process/supervisor.dart';
import '../harness/everyai/git_bash.dart' show findGitBash;
import '../harness/everyai/shell_io.dart' show ShellEnv;
import '../harness/harness.dart' show HarnessError;
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
  try {
    return _Pty.of(
      spawnPty(
        supervisor,
        SpawnSpec(
          // Not one of the agent's processes: the owner carries no session tag, so Stop leaves this shell alone.
          owner: owner ?? const AppOwner(),
          kind: ProcessKind.pty,
          exe: shell.exe,
          args: shell.args,
          env: {...env, ...shell.env},
          cwd: Directory(workingDir).existsSync() ? workingDir : null,
          label: 'Terminal',
        ),
        rows: rows,
        columns: columns,
      ),
    );
  } on SupervisorClosed catch (e) {
    debugPrint('No terminal while the app quits ($e).');
    return null;
  }
}

/// The supervisor terminals belong to (tests swap in their own).
@visibleForTesting
ProcessSupervisor? debugPtySupervisor;

ProcessSupervisor get supervisor => debugPtySupervisor ?? ProcessSupervisor.instance;

/// Starts a coding CLI under a pty for [owner] (session [sessionTag]'s by default), held by [sup] (the app's when
/// null). Throws [SupervisorClosed] while the app quits.
Future<ShellPty?> startProgram({
  required String executable,
  required List<String> args,
  required String workingDir,
  required String sessionTag,
  int rows = 24,
  int columns = 80,
  Map<String, String> env = const {},
  ProcessOwner? owner,
  ProcessSupervisor? sup,
  String? label,
}) async {
  if (!shellSupported) return null;
  // No fallback folder: a coding CLI must not run (and edit files) wherever the app happens to be.
  if (!Directory(workingDir).existsSync()) throw HarnessError("The session's folder is missing.");
  final shell = await ShellEnv.load();
  return _Pty.of(
    spawnPty(
      sup ?? supervisor,
      SpawnSpec(
        owner: owner ?? SessionOwner(sessionTag),
        // The session's lead (a terminal driver's CLI): Stop keeps it, delete and quit end it.
        kind: ProcessKind.leadCli,
        exe: executable,
        args: args,
        env: programEnv(shell.env, env, sessionTag),
        includeParentEnvironment: false,
        cwd: workingDir,
        label: label ?? executable.split('/').last,
      ),
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
  _Pty(this._pty, this.child);
  _Pty.of(SupervisedPty p) : this(p.pty, p.child);
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
