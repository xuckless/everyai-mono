import 'dart:typed_data';

import '../../../core/process/supervisor.dart' show KillOutcome, ProcessOwner, ProcessSupervisor, SupervisedChild;
import '../harness/session_processes.dart' show sessionEnvVar;
import 'pty_stub.dart' if (dart.library.io) 'pty_io.dart' as impl;

export '../../../core/process/supervisor.dart' show KillOutcome;

/// A program in a pseudo-terminal, owned by the process supervisor (adopted right after flutter_pty starts it).
abstract interface class ShellPty {
  int get pid;

  /// Its supervisor record: its state ([SupervisedChild.state]) is the truth about the process.
  SupervisedChild get child;
  Stream<Uint8List> get output;
  Future<int> get exitCode;
  void write(Uint8List data);
  void resize(int rows, int columns);

  /// Ends it and everything it started (verified, through the supervisor), then lets the terminal go. What came
  /// of it: [KillOutcome] (a survivor means it is not closed, and stays listed).
  Future<KillOutcome> kill();
}

/// Where a terminal outside any session starts (Code home): `C:\\` on Windows, else the home folder.
String get terminalHomeDir => impl.terminalHomeDir;

/// Whether this platform can run [startShell].
bool get shellSupported => impl.shellSupported;

/// Starts the user's shell in [workingDir], or null where there is none (or the app is quitting).
/// [env] is added to the app's own environment.
///
/// A user's terminal: it carries the app's tags (`EVERYAI_APP`, `EVERYAI_OWNER` = [owner], the app by default) so
/// quit, the watchdog and the next launch's sweep own it, but never `EVERYAI_SESSION`, so an agent's Stop (which
/// matches that tag) leaves the user's terminal and what they run in it alone.
ShellPty? startShell({
  required String workingDir,
  int rows = 24,
  int columns = 80,
  Map<String, String> env = const {},
  ProcessOwner? owner,
}) => impl.startShell(workingDir: workingDir, rows: rows, columns: columns, env: env, owner: owner);

/// Starts [executable] (an absolute path) in a pseudo-terminal in [workingDir], for a coding CLI the session owns:
/// the login shell's PATH, a colour terminal, and `EVERYAI_SESSION` = [sessionTag] so Stop and the Processes pane
/// own what it runs. Null where there are no ptys. It is adopted once, here, by [sup] (the app's supervisor when
/// null) for [owner] (`SessionOwner(sessionTag)` when null) under [label]; the caller stops it through
/// [ShellPty.child] / [ShellPty.kill]. Throws `SupervisorClosed` while the app quits.
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
}) => impl.startProgram(
  executable: executable,
  args: args,
  workingDir: workingDir,
  sessionTag: sessionTag,
  rows: rows,
  columns: columns,
  env: env,
  owner: owner,
  sup: sup,
  label: label,
);

/// The environment for a CLI in a pty: [base] (the login shell's) made fit for a terminal UI (the shell capture
/// forces `TERM=dumb`, no colour and `cat` as pager), plus [extra] and the session tag.
Map<String, String> programEnv(Map<String, String> base, Map<String, String> extra, String sessionTag) => {
  for (final e in base.entries)
    if (!const {'NO_COLOR', 'PAGER', 'GIT_PAGER'}.contains(e.key)) e.key: e.value,
  ...extra,
  'TERM': 'xterm-256color',
  sessionEnvVar: sessionTag,
};
