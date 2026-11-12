// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../../../core/process/process_model.dart';
import '../domain/fm.dart';
import '../domain/hardware.dart';
import '../domain/local_server.dart';
import 'local_system.dart';

LocalSystem createLocalSystem() => const _NoLocalSystem();

/// The web and phones: no local servers here.
final class _NoLocalSystem implements LocalSystem {
  const _NoLocalSystem();
  static const _why = 'Local servers run on desktops only.';
  @override
  HostOs get os => HostOs.other;
  @override
  Future<HardwareSpec> hardware() async => HardwareSpec.unknown;
  @override
  Future<String?> ollamaPath() async => null;
  @override
  Future<String?> lmsPath() async => null;
  @override
  Future<FmStatus> fmStatus() async => FmStatus.missing;
  @override
  Future<({int code, String out})?> run(String exe, List<String> args, {bool duringQuit = false}) async => null;
  @override
  Future<LaunchedServer?> launch(
    String id,
    String exe,
    List<String> args, {
    Map<String, String> env = const {},
    bool shell = false,
    String? logPath,
    int? port,
  }) async => null;
  @override
  String? get launchProblem => _why;
  @override
  bool owns(String id) => false;
  @override
  int? ownedPort(String id) => null;
  @override
  Future<ServerStopResult> stopOwned(String id, {Duration grace = const Duration(seconds: 5)}) async =>
      const ServerStopEnded();
  @override
  Future<ServerStopResult> stopListener(
    LocalServer server, {
    required int port,
    Duration grace = const Duration(seconds: 5),
  }) async => const ServerStopRefused(_why);
  @override
  Future<int?> freePort() async => null;
  @override
  Future<KillOutcome> stopAllOwned() async => const Ended([]);
  @override
  Future<String?> logDir() async => null;
}

bool get runningUnderTest => false;
