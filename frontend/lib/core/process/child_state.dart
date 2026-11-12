// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/foundation.dart';

/// One process as the OS knows it: its pid, its process group and when it started. A pid can be reused, but not
/// with the same start time, so a pid is only ever signalled while its start time still matches.
@immutable
final class ProcessIdentity {
  const ProcessIdentity({required this.pid, required this.pgid, required this.start});

  final int pid;

  /// Its process group. Equal to [pid] when it leads a group of its own (every child the supervisor spawns on
  /// macOS and Linux); the app's own group for an adopted process.
  final int pgid;

  /// Its start time as a token: `ps -o lstart=` with each run of whitespace turned into one `_` (macOS, Linux), or
  /// a FILETIME number (Windows).
  final String start;

  /// Whether it leads a process group of its own (so the whole group can be signalled).
  bool get leadsGroup => pgid == pid;

  Map<String, Object?> toJson() => {'pid': pid, 'pgid': pgid, 'start': start};

  static ProcessIdentity? fromJson(Object? json) => switch (json) {
    {'pid': final int pid, 'pgid': final int pgid, 'start': final String start} => ProcessIdentity(
      pid: pid,
      pgid: pgid,
      start: start,
    ),
    _ => null,
  };

  @override
  bool operator ==(Object other) =>
      other is ProcessIdentity && other.pid == pid && other.pgid == pgid && other.start == start;
  @override
  int get hashCode => Object.hash(pid, pgid, start);
  @override
  String toString() => '$pid(pg $pgid, $start)';
}

/// How a child's end was seen. Only these two count: the exit future of the process the app waits on, or a scan
/// showing that pid with that start time is gone.
@immutable
sealed class ExitSeen {
  const ExitSeen();
}

/// The process's own exit (the future `Process.exitCode` or a pty's). On macOS a spawned child's code comes from
/// the small shell that holds it in its own group, so a signal reads as 128 + its number there.
final class ExitCode extends ExitSeen {
  const ExitCode(this.code);
  final int code;
  @override
  bool operator ==(Object other) => other is ExitCode && other.code == code;
  @override
  int get hashCode => code.hashCode;
  @override
  String toString() => 'code $code';
}

/// A scan showed the pid gone, or alive with another start time (an adopted process, or one whose exit the app
/// can't wait on). Its exit code is unknown.
final class SeenGone extends ExitSeen {
  const SeenGone();
  @override
  bool operator ==(Object other) => other is SeenGone;
  @override
  int get hashCode => 7;
  @override
  String toString() => 'seen gone';
}

/// Where a child process the supervisor owns is in its life. Every change goes through [nextChildState]:
///
/// ```text
///                landed(id)                 TERM sent            KILL sent
///   Starting ───────────────▶ Running(id) ───────────▶ Terming ───────────▶ Killing
///     │  │                      │  │ KILL sent            │                   │
///     │  │ startFailed          │  └──────────────────────┼──────────────────▶│
///     │  ▼                      │                         │ survivors          │ survivors
///     │ StartFailed             │ exit                    ▼                   ▼
///     │                         │                     NotClosed(survivors, reason) ◀─┐
///     │ exit (ended before      ▼                       │ ▲  │ TERM/KILL sent (retry) │
///     └──its pid was read)──▶ Exited(how) ◀──── exit ───┘ │  └──▶ Terming / Killing ──┘
///                               │  survivors (its group left processes behind)
///                               └──────────────────────────┘
/// ```
///
/// Terming, Killing and NotClosed also end in Exited on an exit. Exited is only reached on the process's own exit
/// future or a pid + start-time check ([ExitSeen]); never because a signal was sent. NotClosed stays listed, is
/// retried by the next stop, and is loud (the state stream and the log).
@immutable
sealed class ChildState {
  const ChildState();

  /// Whether the child still needs ending (it is listed, and quit stops it).
  bool get live => switch (this) {
    ChildExited() || ChildStartFailed() => false,
    _ => true,
  };

  String get name;
}

final class ChildStarting extends ChildState {
  const ChildStarting();
  @override
  String get name => 'starting';
  @override
  bool operator ==(Object other) => other is ChildStarting;
  @override
  int get hashCode => 0;
  @override
  String toString() => 'Starting';
}

final class ChildRunning extends ChildState {
  const ChildRunning(this.id, this.startedAt);
  final ProcessIdentity id;
  final DateTime startedAt;
  int get pid => id.pid;
  int get pgid => id.pgid;
  @override
  String get name => 'running';
  @override
  bool operator ==(Object other) => other is ChildRunning && other.id == id && other.startedAt == startedAt;
  @override
  int get hashCode => Object.hash(1, id, startedAt);
  @override
  String toString() => 'Running($id)';
}

final class ChildTerming extends ChildState {
  const ChildTerming(this.id, this.since);
  final ProcessIdentity id;
  final DateTime since;
  @override
  String get name => 'terming';
  @override
  bool operator ==(Object other) => other is ChildTerming && other.id == id && other.since == since;
  @override
  int get hashCode => Object.hash(2, id, since);
  @override
  String toString() => 'Terming($id)';
}

final class ChildKilling extends ChildState {
  const ChildKilling(this.id, this.since);
  final ProcessIdentity id;
  final DateTime since;
  @override
  String get name => 'killing';
  @override
  bool operator ==(Object other) => other is ChildKilling && other.id == id && other.since == since;
  @override
  int get hashCode => Object.hash(3, id, since);
  @override
  String toString() => 'Killing($id)';
}

final class ChildExited extends ChildState {
  const ChildExited(this.how);
  final ExitSeen how;

  /// The exit code, when the process's own exit was seen.
  int? get code => switch (how) {
    ExitCode(:final code) => code,
    SeenGone() => null,
  };
  @override
  String get name => 'exited';
  @override
  bool operator ==(Object other) => other is ChildExited && other.how == how;
  @override
  int get hashCode => Object.hash(4, how);
  @override
  String toString() => 'Exited($how)';
}

final class ChildNotClosed extends ChildState {
  const ChildNotClosed(this.survivors, this.reason);

  /// What is still running (the child, or what its group or tree left behind), by pid + start time.
  final List<ProcessIdentity> survivors;
  final String reason;
  @override
  String get name => 'notClosed';
  @override
  bool operator ==(Object other) =>
      other is ChildNotClosed && listEquals(other.survivors, survivors) && other.reason == reason;
  @override
  int get hashCode => Object.hash(5, Object.hashAll(survivors), reason);
  @override
  String toString() => 'NotClosed($survivors: $reason)';
}

final class ChildStartFailed extends ChildState {
  const ChildStartFailed(this.error);
  final String error;
  @override
  String get name => 'startFailed';
  @override
  bool operator ==(Object other) => other is ChildStartFailed && other.error == error;
  @override
  int get hashCode => Object.hash(6, error);
  @override
  String toString() => 'StartFailed($error)';
}

/// What happened to a child.
@immutable
sealed class ChildChange {
  const ChildChange();
}

/// Its pid, group and start time were read.
final class ChildLanded extends ChildChange {
  const ChildLanded(this.id, this.at);
  final ProcessIdentity id;
  final DateTime at;
  @override
  String toString() => 'landed($id)';
}

final class ChildFailedToStart extends ChildChange {
  const ChildFailedToStart(this.error);
  final String error;
  @override
  String toString() => 'startFailed';
}

final class ChildTermSent extends ChildChange {
  const ChildTermSent(this.at);
  final DateTime at;
  @override
  String toString() => 'TERM sent';
}

final class ChildKillSent extends ChildChange {
  const ChildKillSent(this.at);
  final DateTime at;
  @override
  String toString() => 'KILL sent';
}

final class ChildExitSeen extends ChildChange {
  const ChildExitSeen(this.how);
  final ExitSeen how;
  @override
  String toString() => 'exit($how)';
}

/// The re-scan after a stop found these still running.
final class ChildSurvivors extends ChildChange {
  const ChildSurvivors(this.survivors, this.reason);
  final List<ProcessIdentity> survivors;
  final String reason;
  @override
  String toString() => 'survivors($survivors)';
}

/// What an event does in a state: a move, nothing on purpose (listed in the table), or a refused move (a bug in
/// the caller).
@immutable
sealed class ChildStep {
  const ChildStep();
}

final class ChildMoves extends ChildStep {
  const ChildMoves(this.next);
  final ChildState next;
}

/// The event changes nothing here, by design: a second TERM while one is under way, the real exit future landing
/// after a scan already saw the process gone, the stop going on to end what the child's group left behind.
final class ChildStays extends ChildStep {
  const ChildStays();
}

final class ChildRefused extends ChildStep {
  const ChildRefused();
}

/// The one transition table (see the diagram on [ChildState]).
ChildStep nextChildState(ChildState from, ChildChange event) => switch ((from, event)) {
  (ChildStarting(), ChildLanded(:final id, :final at)) => ChildMoves(ChildRunning(id, at)),
  (ChildStarting(), ChildFailedToStart(:final error)) => ChildMoves(ChildStartFailed(error)),
  // It ended before its pid could be read (a short command).
  (ChildStarting(), ChildExitSeen(:final how)) => ChildMoves(ChildExited(how)),
  (ChildRunning(:final id), ChildTermSent(:final at)) => ChildMoves(ChildTerming(id, at)),
  (ChildRunning(:final id), ChildKillSent(:final at)) => ChildMoves(ChildKilling(id, at)),
  (ChildRunning(), ChildExitSeen(:final how)) => ChildMoves(ChildExited(how)),
  (ChildTerming(), ChildTermSent()) => const ChildStays(),
  (ChildTerming(:final id), ChildKillSent(:final at)) => ChildMoves(ChildKilling(id, at)),
  (ChildTerming(), ChildExitSeen(:final how)) => ChildMoves(ChildExited(how)),
  (ChildTerming(), ChildSurvivors(:final survivors, :final reason)) => ChildMoves(ChildNotClosed(survivors, reason)),
  (ChildKilling(), ChildTermSent() || ChildKillSent()) => const ChildStays(),
  (ChildKilling(), ChildExitSeen(:final how)) => ChildMoves(ChildExited(how)),
  (ChildKilling(), ChildSurvivors(:final survivors, :final reason)) => ChildMoves(ChildNotClosed(survivors, reason)),
  // The child itself is gone; a stop may still be ending what its tree left behind.
  (ChildExited(), ChildExitSeen() || ChildTermSent() || ChildKillSent()) => const ChildStays(),
  (ChildExited(), ChildSurvivors(:final survivors, :final reason)) => ChildMoves(ChildNotClosed(survivors, reason)),
  // A retry: the next stop starts over from the survivors.
  (ChildNotClosed(:final survivors), ChildTermSent(:final at)) => ChildMoves(ChildTerming(survivors.first, at)),
  (ChildNotClosed(:final survivors), ChildKillSent(:final at)) => ChildMoves(ChildKilling(survivors.first, at)),
  (ChildNotClosed(), ChildExitSeen(:final how)) => ChildMoves(ChildExited(how)),
  (ChildNotClosed(), ChildSurvivors(:final survivors, :final reason)) => ChildMoves(ChildNotClosed(survivors, reason)),
  _ => const ChildRefused(),
};

/// One refused move, kept for tests and diagnostics.
typedef RefusedChildTransition = ({String label, ChildState from, ChildChange event});

/// Every refused move since start (or since a test cleared it).
final refusedChildTransitions = <RefusedChildTransition>[];

/// Whether a refused move asserts (debug builds). Tests that check refusals turn it off.
@visibleForTesting
bool assertOnRefusedChildTransition = true;

/// Moves [from] by [event], or records the refusal and stays: a refused move is a bug in the caller, so debug
/// builds assert.
ChildState applyChildEvent(ChildState from, ChildChange event, {String label = ''}) {
  switch (nextChildState(from, event)) {
    case ChildMoves(:final next):
      return next;
    case ChildStays():
      return from;
    case ChildRefused():
      refusedChildTransitions.add((label: label, from: from, event: event));
      debugPrint('Refused child-process transition ($label): $from + $event');
      assert(!assertOnRefusedChildTransition, 'Refused child-process transition ($label): $from + $event');
      return from;
  }
}
