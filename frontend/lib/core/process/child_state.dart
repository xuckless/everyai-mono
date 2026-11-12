// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/foundation.dart';

/// The start token of a process whose start time hasn't been (or can't be) read.
const unknownStart = '?';

/// Which process group a process is in, as far as killing goes.
@immutable
sealed class ProcessGroup {
  const ProcessGroup();
}

/// It leads a group (and session) of its own: the whole group can be signalled.
final class OwnGroup extends ProcessGroup {
  const OwnGroup();
  @override
  bool operator ==(Object other) => other is OwnGroup;
  @override
  int get hashCode => 1;
  @override
  String toString() => 'own';
}

/// It is in another process's group (the app's, for an adopted process or one started without a launcher): only
/// its tree is ended, never the group.
final class SharedGroup extends ProcessGroup {
  const SharedGroup(this.pgid);
  final int pgid;
  @override
  bool operator ==(Object other) => other is SharedGroup && other.pgid == pgid;
  @override
  int get hashCode => Object.hash(2, pgid);
  @override
  String toString() => 'shared $pgid';
}

/// Process groups don't exist here (Windows).
final class NoGroups extends ProcessGroup {
  const NoGroups();
  @override
  bool operator ==(Object other) => other is NoGroups;
  @override
  int get hashCode => 3;
  @override
  String toString() => 'none';
}

/// One process as the OS knows it: its pid, when it started and its group. A pid can be reused, but not with the
/// same start time, so a pid is only ever signalled while its start time still matches.
@immutable
final class ProcessIdentity {
  const ProcessIdentity({required this.pid, required this.start, this.group = const OwnGroup()});

  final int pid;

  /// Its start time as a token: `ps -o lstart=` with each run of whitespace turned into one `_` (macOS, Linux), or
  /// [unknownStart] (Windows, or not read).
  final String start;
  final ProcessGroup group;

  bool get leadsGroup => group is OwnGroup;

  /// The group id, where there is one.
  int? get pgid => switch (group) {
    OwnGroup() => pid,
    SharedGroup(:final pgid) => pgid,
    NoGroups() => null,
  };

  bool get startKnown => start != unknownStart;

  Map<String, Object?> toJson() => {
    'pid': pid,
    'start': start,
    'group': switch (group) {
      OwnGroup() => 'own',
      SharedGroup(:final pgid) => 'shared:$pgid',
      NoGroups() => 'none',
    },
  };

  static ProcessIdentity? fromJson(Object? json) => switch (json) {
    {'pid': final int pid, 'start': final String start} => ProcessIdentity(
      pid: pid,
      start: start,
      group: switch (json['group']) {
        'own' => const OwnGroup(),
        'none' => const NoGroups(),
        final String g when g.startsWith('shared:') => SharedGroup(int.tryParse(g.substring(7)) ?? 0),
        // An older line: {pgid}
        _ => json['pgid'] == pid ? const OwnGroup() : SharedGroup(json['pgid'] is int ? json['pgid'] as int : 0),
      },
    ),
    _ => null,
  };

  @override
  bool operator ==(Object other) =>
      other is ProcessIdentity && other.pid == pid && other.start == start && other.group == group;
  @override
  int get hashCode => Object.hash(pid, start, group);
  @override
  String toString() => '$pid($group, $start)';
}

/// How a child's end was seen. Only these two count: the exit future of the process the app waits on, or a scan
/// showing that pid with that start time is gone.
@immutable
sealed class ExitSeen {
  const ExitSeen();
}

/// The process's own exit (`Process.exitCode`, a pty's): the program's real code, negative for a signal.
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

/// A scan showed the pid gone, or alive with another start time (an adopted process the app can't wait on). Its
/// exit code is unknown.
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
///            spawned(pid)              landed(id)
///   Starting ────────────▶ Launched(pid) ────────▶ Running(id) ──TERM──▶ Terming ──KILL──▶ Killing
///     │                      │   │ unverifiable      ▲   │                  │                 │
///     │ startFailed          │   ▼                   │   │ KILL             │ survivors       │ survivors
///     ▼                      │ Unverified(pid, why) ─┘   └──────────────────┼────────────────▶│
///   StartFailed              │   │  (landed later)                          ▼                 ▼
///                            │   │ TERM / KILL (by tree) ──▶ Terming / Killing      NotClosed(survivors, reason)
///                            │   │                                                    │  ▲   │ TERM/KILL: retry
///                            ▼   ▼            exit                                    │  │   ▼
///                         Exited(how, at) ◀───────────────────────────── exit ────────┘  └─ Terming / Killing
///                            │ survivors (its group or tree left processes behind)
///                            └──────────────────────────────▶ NotClosed
///
///   Launched / Unverified ──notOurs(why)──▶ Disowned(pid, why)   (an adoption whose expected start didn't match)
/// ```
///
/// Launched, Running, Unverified, Terming and Killing all end in Exited on an exit. Exited is only reached on the
/// process's own exit future or a pid + start-time check ([ExitSeen]); never because a signal was sent. NotClosed
/// and Unverified stay listed and are loud (the state stream and the log); NotClosed is re-checked until gone.
@immutable
sealed class ChildState {
  const ChildState();

  /// Whether the child still needs ending (it is listed, and quit stops it).
  bool get live => switch (this) {
    ChildExited() || ChildStartFailed() || ChildDisowned() => false,
    _ => true,
  };

  String get name;
}

/// `Process.start` hasn't returned yet.
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

/// Started: its pid is known, its start time is being read.
final class ChildLaunched extends ChildState {
  const ChildLaunched(this.pid, this.at, {this.group = const OwnGroup()});
  final int pid;

  /// When it was started (for matching it by start time before that is read).
  final DateTime at;

  /// The group it was started in (its own with a launcher; [SharedGroup] / [NoGroups] without).
  final ProcessGroup group;
  @override
  String get name => 'launched';
  @override
  bool operator ==(Object other) =>
      other is ChildLaunched && other.pid == pid && other.at == at && other.group == group;
  @override
  int get hashCode => Object.hash(8, pid, at, group);
  @override
  String toString() => 'Launched($pid)';
}

final class ChildRunning extends ChildState {
  const ChildRunning(this.id, this.startedAt);
  final ProcessIdentity id;
  final DateTime startedAt;
  int get pid => id.pid;
  @override
  String get name => 'running';
  @override
  bool operator ==(Object other) => other is ChildRunning && other.id == id && other.startedAt == startedAt;
  @override
  int get hashCode => Object.hash(1, id, startedAt);
  @override
  String toString() => 'Running($id)';
}

/// Running, but its start time couldn't be read (the process table failed, or it isn't listed): it can be ended by
/// pid and tree only, and nothing about it can be checked. Loud.
final class ChildUnverified extends ChildState {
  const ChildUnverified(this.pid, this.at, this.why, {this.group = const OwnGroup()});
  final int pid;
  final DateTime at;
  final String why;
  final ProcessGroup group;
  @override
  String get name => 'unverified';
  @override
  bool operator ==(Object other) =>
      other is ChildUnverified && other.pid == pid && other.why == why && other.at == at && other.group == group;
  @override
  int get hashCode => Object.hash(9, pid, why, at, group);
  @override
  String toString() => 'Unverified($pid: $why)';
}

/// SIGTERM sent. [id]'s start is [unknownStart] when the child wasn't verified.
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
  const ChildExited(this.how, this.at);
  final ExitSeen how;

  /// When the end was seen.
  final DateTime at;

  /// The exit code, when the process's own exit was seen.
  int? get code => switch (how) {
    ExitCode(:final code) => code,
    SeenGone() => null,
  };
  @override
  String get name => 'exited';
  @override
  bool operator ==(Object other) => other is ChildExited && other.how == how && other.at == at;
  @override
  int get hashCode => Object.hash(4, how, at);
  @override
  String toString() => 'Exited($how)';
}

final class ChildNotClosed extends ChildState {
  const ChildNotClosed(this.survivors, this.reason);

  /// What is still running (the child, or what its group or tree left behind), by pid + start time (or
  /// [unknownStart] where it couldn't be read). Never empty.
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

/// Adopted, but the process at that pid isn't the one expected (another start time, started too long ago, or it
/// couldn't be checked): never signalled, not listed.
final class ChildDisowned extends ChildState {
  const ChildDisowned(this.pid, this.why);
  final int pid;
  final String why;
  @override
  String get name => 'disowned';
  @override
  bool operator ==(Object other) => other is ChildDisowned && other.pid == pid && other.why == why;
  @override
  int get hashCode => Object.hash(10, pid, why);
  @override
  String toString() => 'Disowned($pid: $why)';
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

/// `Process.start` returned (or a process was adopted): its pid.
final class ChildSpawned extends ChildChange {
  const ChildSpawned(this.pid, this.at, {this.group = const OwnGroup()});
  final int pid;
  final DateTime at;
  final ProcessGroup group;
  @override
  String toString() => 'spawned($pid)';
}

/// Its start time (and group) were read.
final class ChildLanded extends ChildChange {
  const ChildLanded(this.id, this.at);
  final ProcessIdentity id;
  final DateTime at;
  @override
  String toString() => 'landed($id)';
}

/// Its start time can't be read.
final class ChildUnverifiable extends ChildChange {
  const ChildUnverifiable(this.why);
  final String why;
  @override
  String toString() => 'unverifiable($why)';
}

/// An adopted pid isn't the process the caller expected.
final class ChildNotOurs extends ChildChange {
  const ChildNotOurs(this.why);
  final String why;
  @override
  String toString() => 'notOurs($why)';
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
  const ChildExitSeen(this.how, this.at);
  final ExitSeen how;
  final DateTime at;
  @override
  String toString() => 'exit($how)';
}

/// The re-scan after a stop found these still running.
final class ChildSurvivors extends ChildChange {
  const ChildSurvivors(this.survivors, this.reason);

  /// Never empty.
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

ProcessIdentity _unchecked(int pid, ProcessGroup group) => ProcessIdentity(pid: pid, start: unknownStart, group: group);

/// The one transition table (see the diagram on [ChildState]).
ChildStep nextChildState(ChildState from, ChildChange event) => switch ((from, event)) {
  (ChildStarting(), ChildSpawned(:final pid, :final at, :final group)) => ChildMoves(
    ChildLaunched(pid, at, group: group),
  ),
  (ChildStarting(), ChildFailedToStart(:final error)) => ChildMoves(ChildStartFailed(error)),
  (ChildLaunched(), ChildLanded(:final id, :final at)) => ChildMoves(ChildRunning(id, at)),
  (ChildLaunched(:final pid, :final at, :final group), ChildUnverifiable(:final why)) => ChildMoves(
    ChildUnverified(pid, at, why, group: group),
  ),
  (ChildLaunched(:final pid, :final group), ChildTermSent(:final at)) => ChildMoves(
    ChildTerming(_unchecked(pid, group), at),
  ),
  (ChildLaunched(:final pid, :final group), ChildKillSent(:final at)) => ChildMoves(
    ChildKilling(_unchecked(pid, group), at),
  ),
  (ChildLaunched(), ChildExitSeen(:final how, :final at)) => ChildMoves(ChildExited(how, at)),
  (ChildLaunched(), ChildSurvivors(:final survivors, :final reason)) => ChildMoves(ChildNotClosed(survivors, reason)),
  (ChildLaunched(:final pid) || ChildUnverified(:final pid), ChildNotOurs(:final why)) => ChildMoves(
    ChildDisowned(pid, why),
  ),
  (ChildRunning(:final id), ChildTermSent(:final at)) => ChildMoves(ChildTerming(id, at)),
  (ChildRunning(:final id), ChildKillSent(:final at)) => ChildMoves(ChildKilling(id, at)),
  (ChildRunning(), ChildExitSeen(:final how, :final at)) => ChildMoves(ChildExited(how, at)),
  (ChildUnverified(), ChildLanded(:final id, :final at)) => ChildMoves(ChildRunning(id, at)),
  (ChildUnverified(), ChildUnverifiable()) => const ChildStays(),
  (ChildUnverified(:final pid, :final group), ChildTermSent(:final at)) => ChildMoves(
    ChildTerming(_unchecked(pid, group), at),
  ),
  (ChildUnverified(:final pid, :final group), ChildKillSent(:final at)) => ChildMoves(
    ChildKilling(_unchecked(pid, group), at),
  ),
  (ChildUnverified(), ChildExitSeen(:final how, :final at)) => ChildMoves(ChildExited(how, at)),
  (ChildUnverified(), ChildSurvivors(:final survivors, :final reason)) => ChildMoves(ChildNotClosed(survivors, reason)),
  (ChildTerming(), ChildTermSent()) => const ChildStays(),
  (ChildTerming(:final id), ChildKillSent(:final at)) => ChildMoves(ChildKilling(id, at)),
  (ChildTerming(), ChildExitSeen(:final how, :final at)) => ChildMoves(ChildExited(how, at)),
  (ChildTerming(), ChildSurvivors(:final survivors, :final reason)) => ChildMoves(ChildNotClosed(survivors, reason)),
  (ChildKilling(), ChildTermSent() || ChildKillSent()) => const ChildStays(),
  (ChildKilling(), ChildExitSeen(:final how, :final at)) => ChildMoves(ChildExited(how, at)),
  (ChildKilling(), ChildSurvivors(:final survivors, :final reason)) => ChildMoves(ChildNotClosed(survivors, reason)),
  // The child itself is gone; a stop may still be ending what its tree left behind.
  (ChildExited(), ChildExitSeen() || ChildTermSent() || ChildKillSent()) => const ChildStays(),
  (ChildExited(), ChildSurvivors(:final survivors, :final reason)) => ChildMoves(ChildNotClosed(survivors, reason)),
  // A retry: the next stop starts over from the survivors.
  (ChildNotClosed(:final survivors), ChildTermSent(:final at)) => ChildMoves(ChildTerming(survivors.first, at)),
  (ChildNotClosed(:final survivors), ChildKillSent(:final at)) => ChildMoves(ChildKilling(survivors.first, at)),
  (ChildNotClosed(), ChildExitSeen(:final how, :final at)) => ChildMoves(ChildExited(how, at)),
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
