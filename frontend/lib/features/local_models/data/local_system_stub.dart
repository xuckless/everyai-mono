// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../domain/fm.dart';
import '../domain/hardware.dart';
import 'local_system.dart';

LocalSystem createLocalSystem() => const _NoLocalSystem();

/// The web and phones: no local servers here.
final class _NoLocalSystem implements LocalSystem {
  const _NoLocalSystem();
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
  Future<({int code, String out})?> run(String exe, List<String> args) async => null;
  @override
  Future<LaunchedServer?> launch(
    String id,
    String exe,
    List<String> args, {
    Map<String, String> env = const {},
    bool shell = false,
    String? logPath,
  }) async => null;
  @override
  String? get launchProblem => 'Local servers run on desktops only.';
  @override
  bool owns(String id) => false;
  @override
  Future<String?> stopOwned(String id, {Duration grace = const Duration(seconds: 5)}) async => null;
  @override
  Future<String?> stopListener(int port, {Duration grace = const Duration(seconds: 5)}) async =>
      'Local servers run on desktops only.';
  @override
  Future<int?> freePort() async => null;
  @override
  Future<void> stopAllOwned() async {}
  @override
  Future<String?> logDir() async => null;
}

bool get runningUnderTest => false;
