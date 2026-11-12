import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../../../core/process/supervisor.dart';
import '../domain/local_ports.dart';
import '../harness/session_processes.dart';
import 'processes.dart';

ProcessSupervisor get _sup => ProcessSupervisor.instance;

const _probe = ProbeOwner('processes-pane');

Future<ProcessListing> listSessionProcesses({
  required String tag,
  required String workingDir,
  required bool ownsDir,
  Set<int> agentRoots = const {},
  Set<int> terminalShells = const {},
}) async {
  // Windows lists processes through a PowerShell start (about a second of
  // CPU), and finds only what is under a known root there: none, no scan.
  if (Platform.isWindows && agentRoots.isEmpty && terminalShells.isEmpty && driverRootsOf(tag).isEmpty) {
    return const ProcessesListed([]);
  }
  final ProcessTable table;
  final List<int> agent;
  switch (await findSessionProcesses(tag: tag, workingDir: workingDir, ownsDir: ownsDir)) {
    case SessionScanFailed(:final why):
      return ProcessesUnreadable(why);
    case SessionListed(table: final t, :final pids):
      table = t;
      agent = pids;
  }
  final origin = <int, ProcessOrigin>{
    for (final p in agent) p: ProcessOrigin.agent,
    for (final root in agentRoots)
      if (table.rows.containsKey(root))
        for (final p in {root, ...table.descendants(root)}) p: ProcessOrigin.agent,
  };
  for (final shell in terminalShells) {
    for (final p in table.descendants(shell)) {
      origin.putIfAbsent(p, () => ProcessOrigin.terminal);
    }
  }
  origin.remove(pid);
  if (origin.isEmpty) return const ProcessesListed([]);
  final ports = await listeningPorts(origin.keys); // unreadable ports: logged; the processes still show
  return ProcessesListed(
    [
      for (final MapEntry(key: p, value: o) in origin.entries)
        if (table.rows[p] case final row?)
          SessionProcess(
            pid: p,
            ppid: row.ppid,
            command: row.command,
            origin: o,
            start: row.start,
            ports: [
              for (final l in ports)
                if (l.pid == p) l,
            ],
          ),
    ]..sort((a, b) => a.pid.compareTo(b.pid)),
  );
}

Future<PortScan> scanListeningPorts(Iterable<int> pids) async {
  if (pids.isEmpty) return const PortsListed([]);
  Future<RunResult> run(String exe, List<String> args) => _sup.runBounded(
    exe,
    args,
    timeout: const Duration(seconds: 5),
    owner: _probe,
    maxOutputBytes: 4 * 1024 * 1024,
    label: exe,
  );
  if (Platform.isLinux) {
    final r = await run('ss', ['-Hltnp']);
    if (r case Finished(code: 0, :final stdout)) {
      return PortsListed(parseSsListen(stdout).where((l) => pids.contains(l.pid)).toList());
    }
  }
  final r = await run('lsof', ['-nP', '-a', '-iTCP', '-sTCP:LISTEN', '-p', pids.join(','), '-Fpn']);
  switch (r) {
    // 1: none of them listens (or some are gone); what it printed still counts.
    case Finished(:final code, :final stdout) when code == 0 || code == 1:
      return PortsListed(parseLsofListen(stdout));
    case Finished(:final code, :final stderr):
      return PortsUnreadable('lsof exited $code: ${stderr.trim()}');
    case TimedOut() || Cancelled() || StartFailed() || Refused():
      return PortsUnreadable('lsof: $r');
  }
}

Future<KillOutcome> killProcess(int pid, {bool force = false, String? expectedStart}) =>
    _sup.killTree(pid, termWait: force ? Duration.zero : null, expectedStart: expectedStart);

Future<String?> outputFileOf(int pid) async {
  try {
    String? path;
    if (Platform.isLinux) {
      path = await Link('/proc/$pid/fd/1').target();
    } else if (Platform.isMacOS) {
      final r = await _sup.runBounded(
        'lsof',
        ['-nP', '-a', '-p', '$pid', '-d', '1', '-Fn'],
        timeout: const Duration(seconds: 5),
        owner: _probe,
        maxOutputBytes: 256 * 1024,
      );
      if (r is! Finished) {
        debugPrint('The output file of $pid could not be read: $r');
        return null;
      }
      path = lsofFileName(r.stdout);
    }
    if (path == null || !path.startsWith('/') || path.startsWith('/dev/')) return null;
    return FileSystemEntity.typeSync(path) == FileSystemEntityType.file ? path : null;
  } on FileSystemException {
    return null;
  }
}
