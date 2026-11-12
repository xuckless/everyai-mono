// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';
import 'dart:io' show systemEncoding;

import 'package:flutter/foundation.dart';

import 'supervisor.dart';

/// The web: no processes to start or end.
ProcessSupervisor createSupervisor(SupervisorHooks hooks, {required String? ledgerDir, required bool app}) =>
    _NoProcesses();

final class _NoProcesses extends ProcessSupervisor {
  static const _why = 'No processes on this platform';
  final _sweep = ValueNotifier<SweepReport?>(null);
  final _children = ValueNotifier<List<SupervisedChild>>(const []);

  @override
  set ledgerDirectory(String path) {}
  @override
  Future<String> get ledgerDirectory async => '';
  @override
  String get appTag => '';
  @override
  Map<String, String> tagsFor(ProcessOwner owner) => const {};
  @override
  Future<SupervisedProcess> spawn(SpawnSpec spec) => Future.error(UnsupportedError(_why));
  @override
  SupervisedChild adopt(
    int pid,
    SpawnSpec spec, {
    Future<int>? exitCode,
    String? expectedStart,
    Duration? startedWithin,
  }) => throw UnsupportedError(_why);
  @override
  Future<DetachedLaunch> launchDetached(
    String exe,
    List<String> args, {
    Map<String, String> env = const {},
    bool includeParentEnvironment = true,
    String? cwd,
    String? label,
  }) async => const LaunchFailed(_why);
  @override
  Future<KillOutcome> stop(SupervisedChild child, {StopTimings? timings}) async => const ScanFailed(_why);
  @override
  Future<KillOutcome> stopOwner(ProcessOwner owner, {bool tagged = true, bool descendants = true}) async =>
      const Ended([]);
  @override
  Future<KillOutcome> killTree(int pid, {Duration? termWait, String? expectedStart}) async => const ScanFailed(_why);
  @override
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
    bool duringQuit = false,
  }) async => const StartFailed(_why);
  @override
  Future<ProcessScan> scan({bool env = false}) async => const ScanFailed(_why);
  @override
  Future<SweepReport> sweepPreviousRuns() async => const SweepReport();
  @override
  ValueListenable<SweepReport?> get lastSweep => _sweep;
  @override
  Future<QuitReport> stopAll({
    StopTimings timings = StopTimings.quit,
    List<Future<void> Function()> before = const [],
  }) async {
    for (final step in before) {
      try {
        await step();
      } on Object catch (e) {
        debugPrint('Process supervisor: a quit step failed ($e); going on.');
      }
    }
    return QuitReport(const [], at: DateTime.now());
  }

  @override
  List<SupervisedChild> get children => const [];
  @override
  ValueListenable<List<SupervisedChild>> get childrenListenable => _children;
  @override
  int liveCount(ProcessOwner owner) => 0;
  @override
  SupervisedChild? byPid(int pid) => null;
  @override
  Duration treeScanInterval = const Duration(seconds: 5);
  @override
  List<LedgerEntry> get ledgerEntries => const [];
  @override
  List<LedgerEntry> get previousRunEntries => const [];
}
