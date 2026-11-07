// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../domain/fm.dart';
import '../domain/hardware.dart';
import 'local_system_stub.dart' if (dart.library.io) 'local_system_io.dart' as impl;

/// What the local-model code needs from the computer: its hardware, Ollama's and `fm`'s programs, and servers we start
/// ourselves (stopped again only if we started them). Tests replace it.
abstract interface class LocalSystem {
  HostOs get os;

  Future<HardwareSpec> hardware();

  /// Where `ollama` is installed, null when it isn't.
  Future<String?> ollamaPath();

  /// Starts `ollama serve` (when it isn't running). False when it couldn't start.
  Future<bool> startOllama(String path);

  Future<FmStatus> fmStatus();

  /// Starts `fm serve` on a free loopback port and returns the port; null when it couldn't start.
  Future<int?> startFm();

  /// Ends the servers this app started; ones the user runs are left alone.
  Future<void> stopStarted();
}

LocalSystem createLocalSystem() => impl.createLocalSystem();

/// True inside `flutter test` (which sets FLUTTER_TEST): app-wide providers then don't probe this computer's ports
/// and programs unless a test asks for it.
bool get runningUnderTest => impl.runningUnderTest;
