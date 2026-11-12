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

  @override
  set ledgerDirectory(String path) {}
  @override
  Future<String> get ledgerDirectory async => '';
  @override
  String get appTag => '';
  @override
  Future<SupervisedProcess> spawn(SpawnSpec spec) => Future.error(UnsupportedError(_why));
  @override
  SupervisedChild adopt(int pid, SpawnSpec spec, {Future<int>? exitCode}) => throw UnsupportedError(_why);
  @override
  Future<KillOutcome> stop(SupervisedChild child) async => const ScanFailed(_why);
  @override
  Future<KillOutcome> stopOwner(ProcessOwner owner, {bool tagged = true, bool descendants = true}) async =>
      const Ended([]);
  @override
  Future<KillOutcome> killTree(int pid, {Duration? termWait}) async => const ScanFailed(_why);
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
    Encoding encoding = systemEncoding,
    String? label,
  }) async => const StartFailed(_why);
  @override
  Future<ProcessScan> scan({bool env = false}) async => const ScanFailed(_why);
  @override
  Future<SweepReport> sweepPreviousRuns() async => const SweepReport();
  @override
  ValueListenable<SweepReport?> get lastSweep => _sweep;
  @override
  Future<QuitReport> stopAll() async => QuitReport(const [], at: DateTime.now());
  @override
  List<SupervisedChild> get children => const [];
  @override
  SupervisedChild? byPid(int pid) => null;
}
