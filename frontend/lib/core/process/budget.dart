// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'supervisor.dart';

// The runaway guard (owner's rule): each session's live processes are counted from the OS (its listed children's
// trees, plus every process tagged with its id); above the budget the session's whole tree is stopped, the session
// fails loudly, and the agent is told why on its next tool result.

/// The default per-session process budget (Preferences [processBudgetKey]).
const defaultProcessBudget = 400;
const processBudgetKey = 'code.process_budget';

/// The most background shells a session keeps live at once; the next is refused to the agent.
const maxBackgroundShells = 16;

/// The refusal for a background shell past [maxBackgroundShells].
String backgroundShellCapText(int live) =>
    'Error: this session already has $live background shells running, the most it may have '
    '($maxBackgroundShells). Stop one you no longer need (kill_shell with its shell_id; bash_output lists their '
    'output) and start this again.';

/// The failure line for a session stopped by the budget.
String processBudgetText(int count, int limit) =>
    'Stopped: it started more than $limit processes ($count were running). Everything it started was ended.';

/// The processes each session in [sessions] answers for in [table]: its listed children ([children], by owner)
/// and processes tagged with its id ([sessionTagEnvVar]: shells, CLIs, tmux trees), each with its whole tree.
Map<String, ({Set<int> roots, Set<int> all})> sessionProcesses(
  ProcessList table,
  Iterable<String> sessions,
  Iterable<({ProcessOwner owner, int? pid})> children,
) {
  final wanted = sessions.toSet();
  final roots = <String, Set<int>>{for (final s in wanted) s: <int>{}};
  for (final c in children) {
    if (c.owner case SessionOwner(:final id) when wanted.contains(id)) {
      if (c.pid case final pid?) roots[id]!.add(pid);
    }
  }
  for (final r in table.rows.values) {
    final tag = r.tag(sessionTagEnvVar);
    if (tag != null && wanted.contains(tag)) roots[tag]!.add(r.pid);
  }
  bool live(int pid) => !(table.rows[pid]?.zombie ?? true);
  return {
    for (final s in wanted)
      s: (
        roots: {...roots[s]!.where(live)},
        all: {
          for (final pid in roots[s]!.where(live)) ...[pid, ...table.descendants(pid).where(live)],
        },
      ),
  };
}

/// How many live processes each session in [sessions] has ([sessionProcesses]).
Map<String, int> countSessionProcesses(
  ProcessList table,
  Iterable<String> sessions,
  Iterable<({ProcessOwner owner, int? pid})> children,
) => {for (final e in sessionProcesses(table, sessions, children).entries) e.key: e.value.all.length};

/// A session's standing against the budget.
@immutable
sealed class BudgetVerdict {
  const BudgetVerdict();
}

final class WithinBudget extends BudgetVerdict {
  const WithinBudget(this.count);
  final int count;
}

final class OverBudget extends BudgetVerdict {
  const OverBudget(this.count, this.limit);
  final int count;
  final int limit;
  String get text => processBudgetText(count, limit);
}

BudgetVerdict judgeBudget(int count, int limit) => count > limit ? OverBudget(count, limit) : WithinBudget(count);

/// The periodic check. [running] names the sessions that run now (none: the scan is skipped); [limit] is read each
/// time (the user may change it); [onBreach] gets each session over it, after its owner was stopped.
final class ProcessBudgetWatch {
  ProcessBudgetWatch({
    required this.supervisor,
    required this.running,
    required this.limit,
    required this.onBreach,
    this.every = const Duration(seconds: 5),
  });

  final ProcessSupervisor supervisor;
  final Set<String> Function() running;
  final int Function() limit;
  final void Function(String session, OverBudget over, KillOutcome stop) onBreach;
  final Duration every;

  Timer? _timer;

  /// What the agent of a stopped session is told on its next tool result (taken once).
  static final _told = <String, String>{};

  /// The note for [session]'s agent, once.
  static String? takeNote(String session) => _told.remove(session);

  @visibleForTesting
  static void debugSetNote(String session, String? note) =>
      note == null ? _told.remove(session) : _told[session] = note;

  void start() => _timer ??= Timer.periodic(every, (_) => unawaited(check()));

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// The check under way, joined by a tick that comes while it runs.
  Future<void>? _inFlight;

  /// One check: scans, counts, stops every session over the limit. A failed scan is logged, never read as "none".
  Future<void> check() => _inFlight ??= _check().whenComplete(() => _inFlight = null);

  Future<void> _check() async {
    final sessions = running();
    if (sessions.isEmpty) return;
    switch (await supervisor.scan(env: true)) {
      case ScanFailed(:final why):
        debugPrint("EveryAI process budget: the process table couldn't be read ($why).");
      case Listed(:final table):
        final found = sessionProcesses(table, sessions, [
          for (final c in supervisor.children) (owner: c.spec.owner, pid: c.pid),
        ]);
        final max = limit();
        for (final e in found.entries) {
          if (judgeBudget(e.value.all.length, max) case final OverBudget over) {
            debugPrint(
              'EveryAI process budget: session ${e.key} has ${over.count} processes (limit $max); stopping it.',
            );
            // Its listed and owner-tagged children, then every tree the session tag names (what stopOwner's own tag
            // doesn't reach), each checked by its start time.
            final outcome = KillOutcome.merge([
              await supervisor.stopOwner(SessionOwner(e.key)),
              for (final pid in e.value.roots)
                if (table.rows[pid] case final row?) await supervisor.killTree(pid, expectedStart: row.start),
            ]);
            if (outcome is! Ended) debugPrint('NOT CLOSED: session ${e.key} over its process budget: $outcome');
            _told[e.key] = '${over.text} Start fewer processes at once.';
            onBreach(e.key, over, outcome);
          }
        }
    }
  }
}
