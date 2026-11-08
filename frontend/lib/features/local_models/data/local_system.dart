// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../domain/fm.dart';
import '../domain/hardware.dart';
import 'local_system_stub.dart' if (dart.library.io) 'local_system_io.dart' as impl;

/// A server process EveryAI launched: [exited] completes with its exit code.
final class LaunchedServer {
  const LaunchedServer({required this.pid, required this.exited});
  final int pid;
  final Future<int> exited;
}

/// What the local-model code needs from the computer: its hardware, the server programs, and the server processes
/// (the ones EveryAI launched, by server id, and the ones it finds listening on a port). Tests replace it.
abstract interface class LocalSystem {
  HostOs get os;

  Future<HardwareSpec> hardware();

  /// Where `ollama` is installed, null when it isn't.
  Future<String?> ollamaPath();

  /// Where LM Studio's `lms` command is, null when it isn't installed.
  Future<String?> lmsPath();

  Future<FmStatus> fmStatus();

  /// Runs a short command (10 s at most): its exit code and output, null when it couldn't run.
  Future<({int code, String out})?> run(String exe, List<String> args);

  /// Launches the server [id] ([exe] [args]; through the shell when [shell], for a user's own start command); its
  /// output goes to [logPath] when given. Null when it couldn't start; [launchProblem] says why. One process per id.
  Future<LaunchedServer?> launch(
    String id,
    String exe,
    List<String> args, {
    Map<String, String> env = const {},
    bool shell = false,
    String? logPath,
  });

  String? get launchProblem;

  /// Whether EveryAI launched the server [id] and its process still runs.
  bool owns(String id);

  /// Ends the process EveryAI launched for [id] and its children: SIGTERM, then SIGKILL after [grace]. Null when
  /// it's gone, else why not.
  Future<String?> stopOwned(String id, {Duration grace = const Duration(seconds: 5)});

  /// Ends whatever listens on loopback [port] (a server EveryAI didn't start), never this app or its own children.
  /// Null when it's gone, else why not.
  Future<String?> stopListener(int port, {Duration grace = const Duration(seconds: 5)});

  /// A free loopback port, null when none could be had.
  Future<int?> freePort();

  /// Ends every server EveryAI launched (quit).
  Future<void> stopAllOwned();

  /// Where server logs go (app data `local-servers/`), null when there's none.
  Future<String?> logDir();
}

LocalSystem createLocalSystem() => impl.createLocalSystem();

/// True inside `flutter test` (which sets FLUTTER_TEST): app-wide providers then don't probe this computer's ports
/// and programs unless a test asks for it.
bool get runningUnderTest => impl.runningUnderTest;
