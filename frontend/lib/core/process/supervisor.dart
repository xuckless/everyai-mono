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

  /// After SIGTERM, before SIGKILL (ended early once everything is gone).
  final Duration termGrace;

  /// After SIGKILL, before what is left counts as survived.
  final Duration killWait;

  /// How often the table is read while waiting.
  final Duration poll;
}

/// What the supervisor reads and signals through; tests replace parts of it.
@immutable
final class SupervisorHooks {
  const SupervisorHooks({this.scan, this.signal, this.timings = const StopTimings(), this.watchdog = false});

  /// Reads the process table (with environments when [env]); the real one when null.
  final Future<ProcessScan> Function({required bool env})? scan;

  /// Sends [signal] to [pid] (a negative pid: that process group) and says whether it was delivered; the real one
  /// when null.
  final bool Function(int pid, ProcessSignal signal)? signal;
  final StopTimings timings;

  /// Whether this supervisor starts the crash watchdog (the app's own does).
  final bool watchdog;
}

/// A child the supervisor owns.
abstract interface class SupervisedChild {
  /// The supervisor's own number for it (the ledger's `id`).
  int get id;
  SpawnSpec get spec;
  ChildState get state;

  /// Every state it moves to (broadcast; the current one is [state]).
  Stream<ChildState> get states;

  /// Its pid, group and start time, once read (an error when it never started).
  Future<ProcessIdentity> get landed;

  /// Its end, as seen ([ExitSeen]).
  Future<ExitSeen> get ended;

  /// Its pid when known: the adopted pid, or the program's once it [landed].
  int? get pid;

  /// Ends it and everything it started; see [ProcessSupervisor.stop].
  Future<KillOutcome> stop();
}

/// A child the supervisor started, with its pipes.
abstract interface class SupervisedProcess implements SupervisedChild {
  IOSink get stdin;
  Stream<List<int>> get stdout;
  Stream<List<int>> get stderr;

  /// The program's exit code (see [ExitCode] for macOS's signal codes).
  Future<int> get exitCode;

  /// Sends [signal] to its whole process group (or the process alone where it has none); a stop is
  /// [SupervisedChild.stop].
  bool signal(ProcessSignal signal);
}

/// The one place the app starts and ends processes: every child in its own process group (macOS, Linux), tagged
/// with [appEnvVar] and [ownerEnvVar], written to a ledger before it starts, ended with a verified kill, and
/// ended by a watchdog or the next launch's sweep when the app dies without quitting.
abstract class ProcessSupervisor {
  /// The app's supervisor. Tests may swap in their own ([ProcessSupervisor.create]).
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

  /// The folder in use, once known.
  Future<String> get ledgerDirectory;

  /// This app's [appEnvVar] value.
  String get appTag;

  /// Starts [spec] in its own process group. Throws a `ProcessException` like `Process.start` when it can't
  /// start; the child is listed (state Starting) before that, so a stop or a quit meanwhile ends it once it lands.
  Future<SupervisedProcess> spawn(SpawnSpec spec);

  /// Takes on a process something else started (flutter_pty): listed, in the ledger, stopped like the rest.
  /// [exitCode] is its exit future when the starter has one; otherwise its end is seen by scans.
  SupervisedChild adopt(int pid, SpawnSpec spec, {Future<int>? exitCode});

  /// Ends [child]: SIGTERM to its group, its tree and what was found for it, a wait (ended early once all are
  /// gone), SIGKILL to what is left, then a check by pid + start time. A second stop joins the one under way; a
  /// stop of a child still starting ends it once it lands; a child not closed is tried again.
  Future<KillOutcome> stop(SupervisedChild child);

  /// Ends every child of [owner]; with [tagged], also every process whose environment names it ([ownerEnvVar],
  /// where the OS shows environments) and this app; with [descendants], their trees.
  Future<KillOutcome> stopOwner(ProcessOwner owner, {bool tagged = true, bool descendants = true});

  /// Ends [pid] and its tree like [stop] (a listed child is stopped as such). For a process the app didn't start
  /// through the supervisor; [termWait] is the SIGTERM grace.
  Future<KillOutcome> killTree(int pid, {Duration? termWait});

  /// Runs [exe] to its end, or until [timeout] / [cancel], when it is stopped (verified) with its whole group.
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
    Encoding encoding = systemEncoding,
    String? label,
  });

  /// The process table now.
  Future<ProcessScan> scan({bool env = false});

  /// Ends what runs that died without quitting left behind (see [SweepReport]); once per app start. Its report is
  /// kept in [lastSweep] for the app to show.
  Future<SweepReport> sweepPreviousRuns();

  /// The report of the sweep this run did, once done.
  ValueListenable<SweepReport?> get lastSweep;

  /// Ends every listed child (the app quits) and writes `quit.json`: what ended, what survived. The ledger is
  /// deleted when everything ended, and kept (for the next launch's sweep) when not.
  Future<QuitReport> stopAll();

  /// The children still listed (live or not closed).
  List<SupervisedChild> get children;

  /// The listed child with [pid].
  SupervisedChild? byPid(int pid);
}
