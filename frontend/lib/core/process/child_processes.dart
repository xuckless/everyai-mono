// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'child_processes_stub.dart' if (dart.library.io) 'child_processes_io.dart' as impl;

/// Where a child process the app started is in its life.
///
/// ```
///   running ──stop──▶ stopping ──exited──▶ exited
///      └────────────exited────────────────▲
/// ```
/// A second stop while stopping joins the first; anything after exited is ignored.
enum ChildPhase { running, stopping, exited }

enum ChildEvent { stop, exited }

/// The next phase, or null when [event] means nothing in [from] (ignored).
ChildPhase? nextChildPhase(ChildPhase from, ChildEvent event) => switch ((from, event)) {
  (ChildPhase.running, ChildEvent.stop) => ChildPhase.stopping,
  (ChildPhase.running, ChildEvent.exited) => ChildPhase.exited,
  (ChildPhase.stopping, ChildEvent.exited) => ChildPhase.exited,
  (ChildPhase.stopping, ChildEvent.stop) => null,
  (ChildPhase.exited, _) => null,
};

/// The programs the app starts and must end: browsers, MCP servers, Xvfb, device streams, Deno, the bundled
/// server. Each is stopped at quit ([stopAll]); one small watchdog per app run ends them if the app dies without
/// quitting (a crash, Force Quit, a killed test run), since none of them notices its parent going.
abstract final class ChildProcesses {
  /// Tracks [pid] (started from [executable]) until [exited] completes.
  static void track(int pid, {required String label, required String executable, required Future<int> exited}) =>
      impl.track(pid, label: label, executable: executable, exited: exited);

  /// The phase of [pid], or null when it isn't tracked (never was, or it exited).
  static ChildPhase? phaseOf(int pid) => impl.phaseOf(pid);

  /// Ends [pid] and its children (SIGTERM, then SIGKILL); a stop already under way is joined.
  static Future<void> stop(int pid) => impl.stop(pid);

  /// Ends every tracked child (the app quits).
  static Future<void> stopAll() => impl.stopAll();

  /// The tracked children, by pid → label (tests, diagnostics).
  static Map<int, String> get tracked => impl.tracked;
}
