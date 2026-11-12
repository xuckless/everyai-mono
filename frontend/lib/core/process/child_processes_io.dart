// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';

import 'child_processes.dart';
import 'supervisor.dart';

// The old registry's calls, kept while the spawners move to the supervisor: each tracked child is adopted by it.

ProcessSupervisor get _sup => ProcessSupervisor.instance;

void track(int pid, {required String label, required String executable, required Future<int> exited}) {
  _sup.adopt(
    pid,
    SpawnSpec(owner: const AppOwner(), kind: ProcessKind.helper, exe: executable, label: label),
    exitCode: exited,
  );
}

ChildPhase? phaseOf(int pid) => switch (_sup.byPid(pid)?.state) {
  ChildStarting() || ChildRunning() => ChildPhase.running,
  ChildTerming() || ChildKilling() || ChildNotClosed() => ChildPhase.stopping,
  ChildExited() || ChildStartFailed() || null => null,
};

Map<int, String> get tracked => {for (final c in _sup.children) ?c.pid: c.spec.label};

Future<void> stop(int pid) async {
  final c = _sup.byPid(pid);
  if (c != null) await _sup.stop(c);
}

Future<void> stopAll() async {
  await _sup.stopAll();
}
