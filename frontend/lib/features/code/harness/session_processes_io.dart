import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../../../core/process/supervisor.dart';
import '../workflows/workflow_bridge.dart' show workflowScriptLabel;
import 'session_processes.dart';

ProcessSupervisor get _sup => ProcessSupervisor.instance;

/// Kinds of the supervisor's children a session's Stop spares (with their trees): the helpers the app runs for
/// the session, which the harness keeps using after a Stop.
const _helperKinds = {
  ProcessKind.leadCli,
  ProcessKind.mcp,
  ProcessKind.lsp,
  ProcessKind.browser,
  ProcessKind.localServer,
  ProcessKind.backend,
  ProcessKind.device,
  ProcessKind.stream,
  ProcessKind.display,
  ProcessKind.helper,
};

Future<KillOutcome> killSessionProcesses({
  required String tag,
  required String workingDir,
  required bool ownsDir,
  Set<int> roots = const {},
  bool workflows = false,
}) async {
  if (tag.isEmpty) return const Ended([]);
  switch (await _scan(tag, workingDir, ownsDir, roots, workflows: workflows)) {
    case SessionScanFailed(:final why):
      debugPrint('Stop of session $tag: its processes could not be listed ($why).');
      return ScanFailed(why);
    case SessionListed(:final table, :final pids):
      if (pids.isEmpty) return const Ended([]);
      // The top of each tree: the supervisor's kill ends the tree below it (and what appears meanwhile).
      final set = pids.toSet();
      final tops = [
        for (final p in pids)
          if (!set.contains(table.rows[p]?.ppid)) p,
      ];
      final out = KillOutcome.merge(await Future.wait([for (final p in tops) _sup.killTree(p)]));
      if (out is! Ended) debugPrint('Stop of session $tag: $out');
      return out;
  }
}

Future<SessionScan> findSessionProcesses({
  required String tag,
  required String workingDir,
  required bool ownsDir,
  Set<int> roots = const {},
}) => _scan(tag, workingDir, ownsDir, roots, workflows: false);

String _real(String dir) {
  try {
    return Directory(dir).absolute.resolveSymbolicLinksSync();
  } on FileSystemException {
    return Directory(dir).absolute.path; // gone: matched as written
  }
}

/// The pids of [children] a session's tag sweep spares (with their trees): the [_helperKinds], and workflow scripts
/// ([workflowScriptLabel]) unless [workflows] (Stop all, a delete, a budget breach, quit). A plain Stop keeps a
/// running workflow's engine, which carries the session's tag like everything else it started.
Set<int> sweepSpares(Iterable<SupervisedChild> children, {required bool workflows}) => {
  for (final c in children)
    if (_helperKinds.contains(c.spec.kind) || (!workflows && c.spec.label == workflowScriptLabel)) ?c.pid,
};

Future<SessionScan> _scan(
  String tag,
  String workingDir,
  bool ownsDir,
  Set<int> roots, {
  required bool workflows,
}) async {
  final windows = Platform.isWindows;
  // No environments and no working directories on Windows: only what the driver roots run. Without one there is
  // nothing to find there, so no PowerShell.
  if (windows && roots.isEmpty) return SessionListed(ProcessTable(const []), const []);
  final scan = await _sup.scan(env: !windows);
  final ProcessList list;
  switch (scan) {
    case ScanFailed(:final why):
      return SessionScanFailed(why);
    case Listed(:final table):
      list = table;
  }
  final table = tableOf(list, windows: windows, self: pid);
  final dir = _real(workingDir);
  final need = table.needsCwd();
  final Map<int, String> cwds;
  if (windows || need.isEmpty) {
    cwds = const {};
  } else if (Platform.isLinux) {
    cwds = {for (final p in need) p: ?_tryLink('/proc/$p/cwd')};
  } else {
    final (found, why) = await _lsofCwds(need);
    if (found == null) return SessionScanFailed(why);
    cwds = found;
  }
  final spared = sweepSpares(_sup.children, workflows: workflows);
  return SessionListed(
    table,
    table.sessionProcesses(
      tag: tag,
      workingDir: dir,
      ownsDir: ownsDir,
      cwds: cwds,
      roots: roots,
      spared: spared,
      self: pid,
      appTag: _sup.appTag,
    ),
  );
}

/// [list] (the supervisor's scan) as a [ProcessTable]: this user's processes with their EveryAI tags. On Windows
/// a process that started before its claimed parent isn't its child (Windows reuses a dead parent's pid): a root.
ProcessTable tableOf(ProcessList list, {required bool windows, required int self}) {
  final uid = list.rows[self]?.uid;
  int created(ScanRow? r) => r == null ? 0 : int.tryParse(r.start) ?? 0;
  return ProcessTable([
    for (final r in list.rows.values)
      if (!r.zombie && (uid == null || r.uid == null || r.uid == uid))
        ProcessRow(
          pid: r.pid,
          ppid: windows && created(list.rows[r.ppid]) > 0 && created(r) > 0 && created(r) < created(list.rows[r.ppid])
              ? 0
              : r.ppid,
          command: r.command,
          envVisible: r.env is EnvRead,
          tag: r.tag(sessionEnvVar),
          owner: r.tag(ownerEnvVar),
          app: r.tag(appEnvVar),
          start: r.start.isEmpty ? null : r.start,
        ),
  ]);
}

/// The working directories of [pids] (macOS, lsof), or null and why when lsof couldn't tell.
Future<(Map<int, String>?, String)> _lsofCwds(List<int> pids) async {
  final r = await _sup.runBounded(
    'lsof',
    ['-a', '-d', 'cwd', '-p', pids.join(','), '-Fn'],
    timeout: const Duration(seconds: 10),
    owner: const ProbeOwner('session-processes'),
    maxOutputBytes: 4 * 1024 * 1024,
  );
  switch (r) {
    // lsof exits 1 when some of the pids are gone; what it listed still counts.
    case Finished(:final code, :final stdout) when code == 0 || code == 1:
      final out = <int, String>{};
      int? current;
      for (final l in stdout.split('\n')) {
        if (l.startsWith('p')) current = int.tryParse(l.substring(1));
        if (l.startsWith('n') && current != null) out[current] = l.substring(1);
      }
      return (out, '');
    case Finished(:final code, :final stderr):
      return (null, 'lsof exited $code: ${stderr.trim()}');
    case TimedOut() || Cancelled() || StartFailed() || Refused():
      return (null, 'lsof: $r');
  }
}

String? _tryLink(String path) {
  try {
    return Link(path).targetSync();
  } on FileSystemException {
    return null;
  }
}
