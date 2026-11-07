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
  Future<bool> startOllama(String path) async => false;
  @override
  Future<FmStatus> fmStatus() async => FmStatus.missing;
  @override
  Future<int?> startFm() async => null;
  @override
  Future<void> stopStarted() async {}
}

bool get runningUnderTest => false;
