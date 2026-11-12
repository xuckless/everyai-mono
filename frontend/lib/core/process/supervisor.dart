// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
// IOSink and ProcessSignal only (types; dart:io compiles on the web). Starting and signalling processes is in
// supervisor_io.dart.
import 'dart:io' show IOSink, ProcessSignal, systemEncoding;

import 'package:flutter/foundation.dart';

import 'child_state.dart';
import 'process_model.dart';
import 'supervisor_stub.dart' if (dart.library.io) 'supervisor_io.dart' as impl;

export 'child_state.dart';
export 'process_model.dart';

/// How long a stop gives each step.
@immutable
final class StopTimings {
  const StopTimings({
    this.termGrace = const Duration(milliseconds: 1500),
    this.killWait = const Duration(seconds: 2),
    this.poll = const Duration(milliseconds: 50),
  });

  /// At quit: short, so every child fits the app's own quit budget.
  static const quit = StopTimings(
    termGrace: Duration(milliseconds: 400),
    killWait: Duration(seconds: 1),
    poll: Duration(milliseconds: 25),
  );

  /// After SIGTERM, before SIGKILL (ended early once everything is gone).
  final Duration termGrace;

  /// After SIGKILL, before what is left counts as survived.
  final Duration killWait;

  /// How often the table is read while waiting.
  final Duration poll;
}

/// A gentle first step a stop takes before SIGTERM: close stdin, a JSON-RPC shutdown, SIGINT. [run] gets the child;
/// the stop goes on once it exits or after [grace].
@immutable
final class PoliteStop {
  const PoliteStop(this.run, {this.grace = const Duration(seconds: 1)});
  final Future<void> Function(SupervisedChild child) run;
  final Duration grace;
}

/// What to start, and for whom.
@immutable
final class SpawnSpec {
  const SpawnSpec({
    required this.owner,
    required this.kind,
    required this.exe,
    this.args = const [],
    this.env = const {},
    this.includeParentEnvironment = true,
    this.cwd,
    String? label,
    this.politeStop,
    this.outlivesApp = false,
    this.port,
    this.detail,
  }) : _label = label; // ignore: prefer_initializing_formals

  final ProcessOwner owner;
  final ProcessKind kind;

  /// A path, or a name looked up on the child's PATH (never through a shell).
  final String exe;
  final List<String> args;

  /// Added to (or, with [includeParentEnvironment] off, instead of) the app's environment.
  final Map<String, String> env;
  final bool includeParentEnvironment;
  final String? cwd;
  final String? _label;

  /// Taken before SIGTERM by every stop of this child.
  final PoliteStop? politeStop;

  /// Started to outlive the app on purpose (open in an editor, reveal a file, the updater's restart): recorded as
  /// not the app's to end, never stopped at quit, swept or watched.
  final bool outlivesApp;

  /// The port it serves, when it does (the ledger, the Processes view).
  final int? port;

  /// Free text for the ledger and diagnostics.
  final String? detail;

  /// What the ledger and diagnostics call it.
  String get label => _label ?? exe;
}

/// How children are put in a session of their own; tests force one.
enum LaunchVia {
  /// The first available below, in this order.
  auto,

  /// `everyai-exec` (tool/exec_helper): setsid() + execv().
  helper,

  /// `/usr/bin/perl -MPOSIX` setsid + exec (macOS without the helper).
  perl,

  /// `setsid` (Linux without the helper).
  setsid,

  /// None: the child shares the app's group and is ended by its tree only.
  shared,
}

/// What the supervisor reads and signals through; tests replace parts of it.
@immutable
final class SupervisorHooks {
  const SupervisorHooks({
    this.scan,
    this.signal,
    this.timings = const StopTimings(),
    this.watchdog = false,
    this.launch = LaunchVia.auto,
  });

  /// Reads the process table (with environments when [env]); the real one when null.
  final Future<ProcessScan> Function({required bool env})? scan;

  /// Sends [signal] to [pid] (a negative pid: that process group) and says whether it was delivered; the real one
  /// when null.
  final bool Function(int pid, ProcessSignal signal)? signal;
  final StopTimings timings;

  /// Whether this supervisor starts the crash watchdog (the app's own does).
  final bool watchdog;
  final LaunchVia launch;
}

/// The supervisor no longer takes children: it is quitting or has quit.
final class SupervisorClosed implements Exception {
  const SupervisorClosed(this.what);
  final String what;
  @override
  String toString() => 'SupervisorClosed: $what (the app is quitting)';
}

/// A child the supervisor owns.
abstract interface class SupervisedChild {
  /// The supervisor's own number for it (the ledger's `id`).
  int get id;
  SpawnSpec get spec;
  ChildState get state;

  /// Every state it moves to (broadcast; the current one is [state]).
  Stream<ChildState> get states;

  /// Its pid, group and start time, once read (an error when that never happens).
  Future<ProcessIdentity> get landed;

  /// Its end, as seen ([ExitSeen]).
  Future<ExitSeen> get ended;

  /// Its pid (known as soon as it is started or adopted; null only while `Process.start` runs).
  int? get pid;

  /// Ends it and everything it started; see [ProcessSupervisor.stop].
  Future<KillOutcome> stop({StopTimings? timings});

  /// Sends [signal] to its whole process group (or the process alone where it has none). A stop is [stop].
  bool signal(ProcessSignal signal);
}

/// A child the supervisor started, with its pipes.
abstract interface class SupervisedProcess implements SupervisedChild {
  IOSink get stdin;
  Stream<List<int>> get stdout;
  Stream<List<int>> get stderr;

  /// The program's own exit code (negative for a signal, as `Process.exitCode`).
  Future<int> get exitCode;
}

/// The one place the app starts and ends processes: every child in a session of its own (macOS, Linux), tagged
/// with [appEnvVar] and [ownerEnvVar], in a ledger as it starts, ended with a verified kill, and ended by a watchdog
/// or the next launch's sweep when the app dies without quitting.
///
/// A pty (flutter_pty starts it): `Pty.start(exe, environment: {...env, ...supervisor.tagsFor(owner)})`, then
/// `supervisor.adopt(pty.pid, SpawnSpec(owner: owner, kind: ProcessKind.pty, exe: exe), exitCode: pty.exitCode)`,
/// and stop it with the child's `stop()`, not `pty.kill()`. It stays in the app's process group (flutter_pty makes
/// its own session for it), so it is ended by its tree.
abstract class ProcessSupervisor {
  /// The app's supervisor (watchdog and launch sweep on; off under `flutter test`). Tests may swap in their own.
  static ProcessSupervisor instance = impl.createSupervisor(
    const SupervisorHooks(watchdog: true),
    ledgerDir: null,
    app: true,
  );

  /// A supervisor of its own (tests): its ledger under [ledgerDir], when given; with [sweepAtStart] it sweeps on
  /// first use like the app's.
  static ProcessSupervisor create({
    SupervisorHooks hooks = const SupervisorHooks(),
    String? ledgerDir,
    bool sweepAtStart = false,
  }) => impl.createSupervisor(hooks, ledgerDir: ledgerDir, app: sweepAtStart);

  /// Where the ledgers, the watchdog's list and `quit.json` go (`<app support>/processes` by default). Set before
  /// the first spawn.
  set ledgerDirectory(String path);

  /// The folder in use (opening the supervisor if it isn't yet).
  Future<String> get ledgerDirectory;

  /// This app's [appEnvVar] value.
  String get appTag;

  /// The variables every child of [owner] carries ([appEnvVar], [ownerEnvVar], [sessionTagEnvVar] for a session):
  /// for processes started elsewhere (a pty) that are then adopted.
  Map<String, String> tagsFor(ProcessOwner owner);

  /// Starts [spec] in a session of its own. Throws a `ProcessException` like `Process.start` when the program is
  /// missing or not executable, and [SupervisorClosed] once quitting. The child is listed (Starting) before that,
  /// so a stop or a quit meanwhile ends it once it is started.
  Future<SupervisedProcess> spawn(SpawnSpec spec);

  /// Takes on a process something else started (flutter_pty): listed, in the ledger, stopped like the rest.
  /// [exitCode] is its exit future when the starter has one; otherwise its end is seen by scans. Throws
  /// [SupervisorClosed] once quitting.
  SupervisedChild adopt(int pid, SpawnSpec spec, {Future<int>? exitCode});

  /// Ends [child]: its polite step if it has one, SIGTERM to its group, its tree and what was seen below it, a
  /// wait (ended early once all are gone), SIGKILL to what is left, then a check by pid + start time. A second stop
  /// joins the one under way; a child not closed is tried again.
  Future<KillOutcome> stop(SupervisedChild child, {StopTimings? timings});

  /// Ends every child of [owner]; with [tagged], also every process whose environment names it ([ownerEnvVar],
  /// where the OS shows environments) and this app; with [descendants], their trees.
  Future<KillOutcome> stopOwner(ProcessOwner owner, {bool tagged = true, bool descendants = true});

  /// Ends [pid] and its tree like [stop] (a listed child is stopped as such). For a process the app didn't start
  /// through the supervisor; [termWait] is the SIGTERM grace.
  Future<KillOutcome> killTree(int pid, {Duration? termWait});

  /// Runs [exe] to its end, or until [timeout] / [cancel], when it is stopped (verified) with its whole group.
  /// Output past [maxOutputBytes] (per pipe) is read and dropped ([RunOutput.truncated]). When the program has
  /// exited but something it started still holds its pipes, that is stopped and noted ([Finished.leftRunning]).
  ///
  /// There is no synchronous version: a blocking run can't be bounded or killed from the same isolate, so the two
  /// `Process.runSync` sites (webview_browser.dart's pid checks) become async or use [scan].
  Future<RunResult> runBounded(
    String exe,
    List<String> args, {
    required Duration timeout,
    Future<void>? cancel,
    ProcessOwner owner = const AppOwner(),
    ProcessKind kind = ProcessKind.oneShot,
    Map<String, String> env = const {},
    bool includeParentEnvironment = true,
    String? cwd,
    String? stdin,
    List<int>? stdinBytes,
    Encoding stdoutEncoding = systemEncoding,
    Encoding stderrEncoding = systemEncoding,
    int? maxOutputBytes,
    String? label,
  });

  /// The process table (shared: concurrent callers get one read).
  Future<ProcessScan> scan({bool env = false});

  /// Ends what runs that died without quitting left behind (see [SweepReport]); once per supervisor. Its report
  /// is kept in [lastSweep] for the app to show.
  Future<SweepReport> sweepPreviousRuns();

  /// The report of the sweep this run did, once done.
  ValueListenable<SweepReport?> get lastSweep;

  /// Ends every listed child (the app quits) with [timings] and writes `quit.json`: what ended, what survived.
  /// The ledger is deleted when everything ended, and kept (for the next launch's sweep) when not. Afterwards
  /// spawns and adoptions are refused ([SupervisorClosed]).
  Future<QuitReport> stopAll({StopTimings timings = StopTimings.quit});

  /// The children still listed (live or not closed).
  List<SupervisedChild> get children;

  /// [children], as they change.
  ValueListenable<List<SupervisedChild>> get childrenListenable;

  /// How many listed children [owner] has.
  int liveCount(ProcessOwner owner);

  /// The listed child with [pid].
  SupervisedChild? byPid(int pid);
}
