// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
// File only, read in a try (dart:io compiles on the web; nothing here runs there: the stub supervisor has no
// ledger folder).
import 'dart:io' show File;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/process/supervisor.dart';
import '../code/session_notifications.dart' show systemNotifierProvider;

/// The supervisor the screens read (tests put their own in).
final processSupervisorProvider = Provider<ProcessSupervisor>((ref) => ProcessSupervisor.instance);

/// How often the Processes screen reads the process table while it is shown.
const ownedScanEvery = Duration(seconds: 3);

/// What the last OS scan says about a child, beside what the supervisor says.
@immutable
sealed class OsSeen {
  const OsSeen();
}

/// No scan yet, or the child isn't meant to be running (exited, failed to start).
final class OsNotChecked extends OsSeen {
  const OsNotChecked();
}

/// The scan shows it (pid with that start time, or the pid alone where the start isn't known).
final class OsConfirmed extends OsSeen {
  const OsConfirmed();
}

/// The supervisor says it runs, but the scan can't find it: shown as "gone (unconfirmed)" until the supervisor sees
/// the end itself.
final class OsMissing extends OsSeen {
  const OsMissing();
}

/// One child the supervisor owns, as the screens show it.
@immutable
final class OwnedProcess {
  const OwnedProcess({
    required this.child,
    required this.id,
    required this.label,
    required this.kind,
    required this.owner,
    required this.pid,
    required this.state,
    required this.port,
    required this.detail,
    required this.started,
    this.os = const OsNotChecked(),
  });

  factory OwnedProcess.of(SupervisedChild c, {OsSeen os = const OsNotChecked()}) {
    final s = c.state;
    return OwnedProcess(
      child: c,
      id: c.id,
      label: c.spec.label,
      kind: c.spec.kind,
      owner: c.spec.owner,
      pid: c.pid,
      state: s,
      port: c.port,
      detail: c.detail,
      started: switch (s) {
        ChildRunning(:final startedAt) => startedAt,
        ChildLaunched(:final at) || ChildUnverified(:final at) => at,
        _ => null,
      },
      os: os,
    );
  }

  final SupervisedChild child;
  final int id;
  final String label;
  final ProcessKind kind;
  final ProcessOwner owner;
  final int? pid;
  final ChildState state;
  final int? port;
  final String? detail;
  final DateTime? started;
  final OsSeen os;

  String get ownerKey => owner.key;

  /// Not closed, or running with nothing able to check it: the loud ones.
  bool get loud => state is ChildNotClosed || state is ChildUnverified;
}

/// What the Processes screen lists: the supervisor's children, joined with the last scan.
@immutable
sealed class OwnedView {
  const OwnedView(this.rows);
  final List<OwnedProcess> rows;
}

/// No scan has come back yet (the supervisor's own states are shown meanwhile).
final class OwnedScanning extends OwnedView {
  const OwnedScanning(super.rows);
}

final class OwnedListed extends OwnedView {
  const OwnedListed(super.rows, {required this.at});
  final DateTime at;
}

/// The process table couldn't be read: never shown as "nothing running".
final class OwnedScanFailed extends OwnedView {
  const OwnedScanFailed(super.rows, this.why);
  final String why;
}

/// What a scan says about [s].
OsSeen osSeenOf(ChildState s, ProcessScan scan) {
  if (scan is! Listed) return const OsNotChecked();
  final t = scan.table;
  final seen = switch (s) {
    ChildRunning(:final id) || ChildTerming(:final id) || ChildKilling(:final id) => t.alive(id),
    ChildLaunched(:final pid, :final at) =>
      t.aliveNear(pid, at) || t.alive(ProcessIdentity(pid: pid, start: unknownStart)),
    ChildUnverified(:final pid) => t.alive(ProcessIdentity(pid: pid, start: unknownStart)),
    ChildNotClosed(:final survivors) => survivors.any(t.alive),
    _ => null,
  };
  return switch (seen) {
    null => const OsNotChecked(),
    true => const OsConfirmed(),
    false => const OsMissing(),
  };
}

/// Joins [children] with [scan] (null: none yet).
OwnedView joinOwned(List<SupervisedChild> children, ProcessScan? scan) {
  final rows = [
    for (final c in children) OwnedProcess.of(c, os: scan == null ? const OsNotChecked() : osSeenOf(c.state, scan)),
  ];
  return switch (scan) {
    null => OwnedScanning(rows),
    Listed(:final at) => OwnedListed(rows, at: at),
    ScanFailed(:final why) => OwnedScanFailed(rows, why),
  };
}

/// Calls [onChange] when the list of children or any child's state changes; returns the cancel.
void Function() _followChildren(ProcessSupervisor sup, void Function() onChange) {
  final subs = <int, StreamSubscription<ChildState>>{};
  void resubscribe() {
    final ids = {for (final c in sup.children) c.id};
    for (final id in subs.keys.toList()) {
      if (!ids.contains(id)) unawaited(subs.remove(id)!.cancel());
    }
    for (final c in sup.children) {
      subs[c.id] ??= c.states.listen((_) => onChange());
    }
  }

  void listChanged() {
    resubscribe();
    onChange();
  }

  sup.childrenListenable.addListener(listChanged);
  resubscribe();
  return () {
    sup.childrenListenable.removeListener(listChanged);
    for (final s in subs.values) {
      unawaited(s.cancel());
    }
  };
}

/// Every child the supervisor owns, joined with an OS scan every [ownedScanEvery] while something watches.
final ownedProcessesProvider = NotifierProvider.autoDispose<OwnedProcesses, OwnedView>(OwnedProcesses.new);

final class OwnedProcesses extends Notifier<OwnedView> {
  ProcessScan? _scan;
  Timer? _timer;
  bool _disposed = false;

  @override
  OwnedView build() {
    final sup = ref.watch(processSupervisorProvider);
    _disposed = false;
    final cancel = _followChildren(sup, () {
      if (!_disposed) state = joinOwned(sup.children, _scan);
    });
    _timer = Timer.periodic(ownedScanEvery, (_) => unawaited(refresh()));
    ref.onDispose(() {
      _disposed = true;
      cancel();
      _timer?.cancel();
    });
    unawaited(refresh());
    return joinOwned(sup.children, _scan);
  }

  /// Reads the table again now.
  Future<void> refresh() async {
    final sup = ref.read(processSupervisorProvider);
    ProcessScan scan;
    try {
      scan = await sup.scan();
    } on Object catch (e) {
      scan = ScanFailed('$e');
    }
    if (_disposed) return;
    _scan = scan;
    state = joinOwned(sup.children, scan);
  }
}

/// This session's children (its own and its terminal tabs').
final ownedBySessionProvider = Provider.autoDispose.family<OwnedView, String>((ref, sessionId) {
  final all = ref.watch(ownedProcessesProvider);
  final rows = [
    for (final r in all.rows)
      if (r.owner case SessionOwner(:final id) || TerminalOwner(sessionId: final id) when id == sessionId) r,
  ];
  return switch (all) {
    OwnedScanning() => OwnedScanning(rows),
    OwnedListed(:final at) => OwnedListed(rows, at: at),
    OwnedScanFailed(:final why) => OwnedScanFailed(rows, why),
  };
});

/// Children in [ChildNotClosed] or [ChildUnverified], from the supervisor alone (no scan, so the shell can watch it
/// for the life of the app). The first time a child becomes Not closed in a run, an OS notification goes out.
final notClosedProvider = NotifierProvider<NotClosed, List<OwnedProcess>>(NotClosed.new);

final class NotClosed extends Notifier<List<OwnedProcess>> {
  final _notified = <int>{};

  @override
  List<OwnedProcess> build() {
    final sup = ref.watch(processSupervisorProvider);
    var alive = true;
    final cancel = _followChildren(sup, () {
      if (alive) state = _read(sup);
    });
    ref.onDispose(() {
      alive = false;
      cancel();
    });
    return _read(sup);
  }

  List<OwnedProcess> _read(ProcessSupervisor sup) {
    final out = [
      for (final c in sup.children)
        if (c.state is ChildNotClosed || c.state is ChildUnverified) OwnedProcess.of(c),
    ];
    for (final p in out) {
      if (p.state case ChildNotClosed(:final survivors) when _notified.add(p.id)) {
        final pids = survivors.map((s) => s.pid).join(', ');
        unawaited(
          ref
              .read(systemNotifierProvider)
              .show("A process didn't close", '${p.label} is still running (pids $pids).')
              .catchError((Object _) {}),
        );
      }
    }
    return out;
  }
}

/// This run's launch sweep, once done.
final lastSweepProvider = NotifierProvider<LastSweep, SweepReport?>(LastSweep.new);

final class LastSweep extends Notifier<SweepReport?> {
  @override
  SweepReport? build() {
    final l = ref.watch(processSupervisorProvider).lastSweep;
    void on() => state = l.value;
    l.addListener(on);
    ref.onDispose(() => l.removeListener(on));
    return l.value;
  }
}

/// One process the previous run's quit couldn't end (or couldn't check).
typedef QuitLeftover = ({String label, List<int> pids, String why});

/// What `quit.json` of the previous run says.
@immutable
sealed class LastQuit {
  const LastQuit();
}

/// No record: a first run, the web, or the folder couldn't be opened.
final class NoQuitRecord extends LastQuit {
  const NoQuitRecord();
}

final class QuitRead extends LastQuit {
  const QuitRead({required this.at, required this.ended, required this.leftovers});
  final DateTime? at;
  final int ended;

  /// Survived, or a scan failed so the end couldn't be checked.
  final List<QuitLeftover> leftovers;
  bool get clean => leftovers.isEmpty;
}

final class QuitUnreadable extends LastQuit {
  const QuitUnreadable(this.why);
  final String why;
}

/// Parses `quit.json` ([QuitReport.toJson]).
LastQuit parseQuitJson(String text) {
  try {
    final j = jsonDecode(text);
    if (j is! Map) return const QuitUnreadable('not an object');
    List<int> pids(Object? v) => [if (v is List) ...v.whereType<int>()];
    final left = <QuitLeftover>[
      for (final e in (j['survived'] as List? ?? const []).whereType<Map<String, dynamic>>())
        (label: '${e['label'] ?? '?'}', pids: pids(e['pids']), why: '${e['reason'] ?? 'survived'}'),
      for (final e in (j['scanFailed'] as List? ?? const []).whereType<Map<String, dynamic>>())
        (label: '${e['label'] ?? '?'}', pids: const <int>[], why: "couldn't check: ${e['why'] ?? '?'}"),
    ];
    return QuitRead(
      at: DateTime.tryParse('${j['at']}'),
      ended: (j['ended'] as List? ?? const []).length,
      leftovers: left,
    );
  } on FormatException catch (e) {
    return QuitUnreadable(e.message);
  }
}

/// The previous run's `quit.json`, read once per run (before this run's quit writes its own) and then removed: a
/// run that crashes writes none, and the launch after it must not read the record of the run before.
final lastQuitProvider = FutureProvider<LastQuit>((ref) async {
  if (kIsWeb) return const NoQuitRecord();
  try {
    final dir = await ref.read(processSupervisorProvider).ledgerDirectory;
    if (dir.isEmpty) return const NoQuitRecord();
    final f = File('$dir/quit.json');
    if (!await f.exists()) return const NoQuitRecord();
    final text = await f.readAsString();
    try {
      await f.delete();
    } on Object catch (e) {
      debugPrint('quit.json could not be removed after reading it: $e');
    }
    return parseQuitJson(text);
  } on Object catch (e) {
    return QuitUnreadable('$e');
  }
});

/// The one launch notice about the last run's leftovers: waiting for the sweep and quit record, then shown once,
/// then dismissed (or nothing to say).
///
/// ```text
///   Pending ──sweep + quit read──▶ Showing(lines) ──dismiss──▶ Dismissed
///      └──────── nothing to say ──▶ Quiet
/// ```
@immutable
sealed class LaunchNotice {
  const LaunchNotice();
}

final class NoticePending extends LaunchNotice {
  const NoticePending();
}

final class NoticeQuiet extends LaunchNotice {
  const NoticeQuiet();
}

/// One line of the notice; [bad] ones are in the error colour.
typedef NoticeLine = ({String text, bool bad});

final class NoticeShowing extends LaunchNotice {
  const NoticeShowing(this.lines);
  final List<NoticeLine> lines;
}

final class NoticeDismissed extends LaunchNotice {
  const NoticeDismissed();
}

/// What the sweep and the quit record say, as notice lines (empty: nothing to say).
List<NoticeLine> launchNoticeLines(SweepReport? sweep, LastQuit? quit) {
  String n(int k) => k == 1 ? '1 process' : '$k processes';
  return [
    if (sweep != null) ...[
      if (sweep.failure case final why?) (text: "Couldn't check for processes left by the last run: $why", bad: true),
      if (sweep.ended.isNotEmpty) (text: 'Cleaned up ${n(sweep.ended.length)} left by the last run', bad: false),
      if (sweep.survived.isNotEmpty)
        (text: "${n(sweep.survived.length)} from the last run couldn't be closed", bad: true),
    ],
    if (quit case QuitRead(:final leftovers) when leftovers.isNotEmpty)
      (text: "The last quit wasn't clean: ${leftovers.map((l) => l.label).join(', ')}", bad: true),
    if (quit case QuitUnreadable(:final why)) (text: "The last quit's record couldn't be read: $why", bad: true),
  ];
}

final launchNoticeProvider = NotifierProvider<LaunchNoticeState, LaunchNotice>(LaunchNoticeState.new);

final class LaunchNoticeState extends Notifier<LaunchNotice> {
  @override
  LaunchNotice build() {
    final sweep = ref.watch(lastSweepProvider);
    final quit = ref.watch(lastQuitProvider);
    if (stateOrNull is NoticeDismissed) return const NoticeDismissed();
    if (stateOrNull case final NoticeShowing s) return s; // shown once: later changes don't replace it
    if (sweep == null || quit.isLoading) return const NoticePending();
    final lines = launchNoticeLines(sweep, quit.value);
    return lines.isEmpty ? const NoticeQuiet() : NoticeShowing(lines);
  }

  void dismiss() => state = const NoticeDismissed();
}

/// The state as words: Starting, Running, Stopping, Killing, Exited n, Not closed.
String childStateText(ChildState s) => switch (s) {
  ChildStarting() || ChildLaunched() => 'Starting',
  ChildRunning() => 'Running',
  ChildUnverified(:final why) => 'Running, unverified ($why)',
  ChildTerming() => 'Stopping',
  ChildKilling() => 'Killing',
  ChildExited(:final code) => code == null ? 'Exited' : 'Exited $code',
  ChildNotClosed(:final survivors) => 'Not closed: pids ${survivors.map((p) => p.pid).join(', ')}',
  ChildDisowned(:final why) => 'Not ours ($why)',
  ChildStartFailed(:final error) => "Couldn't start: $error",
};

/// The state, with the scan's word when it disagrees.
String ownedStateText(OwnedProcess p) => switch ((p.state, p.os)) {
  (ChildNotClosed(), _) => childStateText(p.state),
  (_, OsMissing()) when p.state.live => 'Gone (unconfirmed)',
  _ => childStateText(p.state),
};

/// What a stop did, for a toast: "Stopped" only when everything ended; a second line for possible escapes.
String killOutcomeText(KillOutcome o, String label) => switch (o) {
  Ended(:final maybeEscaped) => [
    'Stopped $label',
    if (maybeEscaped.isNotEmpty) 'Some may have escaped: pids ${maybeEscaped.join(', ')}',
  ].join('\n'),
  Survived(:final pids, :final reason) => 'Not closed: pids ${pids.join(', ')} ($reason)',
  ScanFailed(:final why) => "Not closed: couldn't check ($why)",
};
