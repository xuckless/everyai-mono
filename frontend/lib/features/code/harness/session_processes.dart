import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/process/process_model.dart' show KillOutcome, sessionTagEnvVar;
import 'session_processes_stub.dart' if (dart.library.io) 'session_processes_io.dart' as impl;

export '../../../core/process/process_model.dart' show KillOutcome;

/// Set in the environment of each session's shell commands, so the processes
/// they start can be told apart from other sessions' (the supervisor's
/// `sessionTagEnvVar`).
const sessionEnvVar = sessionTagEnvVar;

/// Ends every process a Code session's terminal left running: background
/// jobs, servers, and commands still going after a soft timeout. The
/// terminal's own shell stays, so the agent can keep working; so do the
/// session's helpers the app runs for it (language and MCP servers, the CLI).
///
/// A process belongs to the session when its environment shows
/// [sessionEnvVar] = [tag] (or the supervisor's owner tag for it), wherever
/// its parent is. macOS hides the environment of system binaries
/// (`/bin/sleep`, `/bin/bash`); an orphaned one counts when its working
/// directory is inside [workingDir] and [ownsDir] says no other session
/// works there (a per-session worktree). Each is ended with the supervisor's
/// verified kill of its tree: the merged outcome ([KillOutcome]); a table
/// that can't be read is a failure, never "nothing". A running workflow's
/// script (and its tree) is spared unless [workflows] (Stop all, a delete, a
/// budget breach, quit).
Future<KillOutcome> killSessionProcesses({
  required String tag,
  required String workingDir,
  required bool ownsDir,
  bool workflows = false,
}) => impl.killSessionProcesses(
  tag: tag,
  workingDir: workingDir,
  ownsDir: ownsDir,
  roots: driverRootsOf(tag),
  workflows: workflows,
);

/// The process table and the pids [killSessionProcesses] would signal, for
/// the Processes pane, or why the table couldn't be read.
Future<SessionScan> findSessionProcesses({required String tag, required String workingDir, required bool ownsDir}) =>
    impl.findSessionProcesses(tag: tag, workingDir: workingDir, ownsDir: ownsDir, roots: driverRootsOf(tag));

/// What a look for a session's processes found.
@immutable
sealed class SessionScan {
  const SessionScan();
}

/// The table, and the session's processes in it.
final class SessionListed extends SessionScan {
  const SessionListed(this.table, this.pids);
  final ProcessTable table;
  final List<int> pids;
}

/// The table couldn't be read: nothing can be said (never read as "nothing running").
final class SessionScanFailed extends SessionScan {
  const SessionScanFailed(this.why);
  final String why;
}

final _driverRoots = <String, Set<int>>{};

/// Marks [pid], a coding CLI the app started for session [tag], as the root
/// of the session's processes: the shells it runs for tool commands are the
/// session's (Stop ends them, the Processes pane lists them), while the CLI
/// itself and its other children (a relaunched agent, a node wrapper's
/// native binary, its MCP or LSP servers) are spared, like the terminal's
/// shell. Its own environment alone wouldn't do: the table follows terminal
/// shells and orphans only.
void registerDriverRoot(String tag, int pid) => (_driverRoots[tag] ??= {}).add(pid);

void unregisterDriverRoot(String tag, int pid) {
  final roots = _driverRoots[tag];
  if (roots == null) return;
  roots.remove(pid);
  if (roots.isEmpty) _driverRoots.remove(tag);
}

/// The driver processes registered for [tag].
Set<int> driverRootsOf(String tag) => {...?_driverRoots[tag]};

/// One row of the process table.
@immutable
final class ProcessRow {
  const ProcessRow({
    required this.pid,
    required this.ppid,
    required this.command,
    this.envVisible = true,
    this.tag,
    this.owner,
    this.app,
    this.start,
  });

  final int pid;
  final int ppid;

  /// The command line (without the environment).
  final String command;

  /// Whether the environment could be read at all.
  final bool envVisible;

  /// The value of [sessionEnvVar], when set and visible.
  final String? tag;

  /// The supervisor's owner tag (`EVERYAI_OWNER`, `session:<id>` for a session's), when set and visible.
  final String? owner;

  /// The supervisor's app tag (`EVERYAI_APP`, `<app pid>:<start>`), when set and visible.
  final String? app;

  /// Its start time as the supervisor's `startToken`, when the table had one: a later kill checks the pid is still
  /// this process.
  final String? start;

  /// The program's name: no folder, and no `.exe` on Windows, where the
  /// path may be quoted (`"C:\Program Files\Git\bin\bash.exe" -c …`).
  String get _exe {
    final line = command.trimLeft();
    final quoted = line.startsWith('"') && line.indexOf('"', 1) > 0;
    final first = quoted ? line.substring(1, line.indexOf('"', 1)) : line.split(RegExp(r'\s')).first;
    final name = first.substring(first.lastIndexOf(RegExp(r'[/\\]')) + 1);
    return name.toLowerCase().endsWith('.exe') ? name.substring(0, name.length - 4) : name;
  }

  /// A tmux server: its children may be shells running the agent's
  /// commands. Never signalled.
  bool get isTerminalHost => _exe == 'tmux';

  /// A shell (`bash -c …`, a login `-zsh`): how coding CLIs run tool commands.
  /// Not `cmd`: on Windows it is mostly a wrapper for `.cmd` shims, and the
  /// CLIs start their MCP and LSP servers through it (`cmd /c npx …`), which
  /// Stop must spare. A tool command under a `cmd` is still found through it.
  bool get isShell => const {
    'sh',
    'bash',
    'zsh',
    'fish',
    'dash',
    'ksh',
    'powershell',
    'pwsh',
  }.contains(_exe.replaceFirst('-', '').toLowerCase());
}

/// The process table, and which processes belong to a session.
final class ProcessTable {
  ProcessTable(Iterable<ProcessRow> rows) : rows = {for (final r in rows) r.pid: r} {
    for (final r in this.rows.values) {
      (_children[r.ppid] ??= []).add(r.pid);
    }
  }

  final Map<int, ProcessRow> rows;
  final _children = <int, List<int>>{};

  static final _envTag = RegExp('(?:^|\\s)$sessionEnvVar=(\\S*)');

  /// Parses `ps -E -ww -x -o pid=,ppid=,command=` (macOS): the environment
  /// follows the arguments when it is readable. [plain] is the same listing
  /// without `-E`; a row whose line is unchanged had no readable environment.
  factory ProcessTable.parsePs(String withEnv, String plain) {
    final commands = <int, String>{};
    for (final (pid, _, rest) in _lines(plain)) {
      commands[pid] = rest;
    }
    return ProcessTable([
      for (final (pid, ppid, rest) in _lines(withEnv))
        if (commands[pid] case final cmd?)
          ProcessRow(
            pid: pid,
            ppid: ppid,
            command: cmd,
            envVisible: rest.length > cmd.length,
            tag: rest.length > cmd.length ? _envTag.firstMatch(rest.substring(cmd.length))?.group(1) : null,
          ),
    ]);
  }

  /// Parses PowerShell's `Get-CimInstance Win32_Process | Select-Object
  /// ProcessId,ParentProcessId,Name,CommandLine,Created | ConvertTo-Json`
  /// (Windows): an array, or one object when there is one row. `Created` is
  /// the start time as a FILETIME (0 when unknown). Windows keeps a dead
  /// parent's pid as ParentProcessId and reuses pids, so a process that
  /// started before its claimed parent isn't its child: it becomes a root.
  /// Windows doesn't show other processes' environments, so there are no tags.
  factory ProcessTable.parseCim(String json) {
    final decoded = jsonDecode(json.trim().isEmpty ? '[]' : json);
    final rows = <({int pid, int ppid, int created, String command})>[
      for (final r in decoded is List ? decoded : [decoded])
        if (r case {'ProcessId': final int pid, 'ParentProcessId': final int ppid})
          (
            pid: pid,
            ppid: ppid,
            created: switch (r['Created']) {
              final int c => c,
              _ => 0,
            },
            command: switch (r['CommandLine']) {
              final String c when c.trim().isNotEmpty => c,
              _ => '${r['Name'] ?? ''}',
            },
          ),
    ];
    final created = {for (final r in rows) r.pid: r.created};
    bool stale(int ppid, int child) {
      final parent = created[ppid] ?? 0;
      return parent > 0 && child > 0 && child < parent;
    }

    return ProcessTable([
      for (final r in rows)
        ProcessRow(pid: r.pid, ppid: stale(r.ppid, r.created) ? 0 : r.ppid, command: r.command, envVisible: false),
    ]);
  }

  static Iterable<(int, int, String)> _lines(String out) sync* {
    final line = RegExp(r'^\s*(\d+)\s+(\d+)\s(.*)$');
    for (final l in out.split('\n')) {
      final m = line.firstMatch(l);
      if (m == null) continue;
      yield (int.parse(m.group(1)!), int.parse(m.group(2)!), m.group(3)!);
    }
  }

  /// The tag in an environment block (`/proc/<pid>/environ`, NUL-separated).
  static String? tagInEnviron(String environ) {
    for (final e in environ.split('\x00')) {
      if (e.startsWith('$sessionEnvVar=')) return e.substring(sessionEnvVar.length + 1);
    }
    return null;
  }

  /// Shells under a tmux server.
  List<int> get shells => [
    for (final r in rows.values)
      if (!r.isTerminalHost && (rows[r.ppid]?.isTerminalHost ?? false)) r.pid,
  ];

  /// Processes whose parent has exited (adopted by init/launchd).
  List<int> get orphans => [
    for (final r in rows.values)
      if (r.ppid == 1 && !r.isTerminalHost) r.pid,
  ];

  List<int> descendants(int pid) {
    final out = <int>[];
    final stack = [...?_children[pid]];
    while (stack.isNotEmpty) {
      final p = stack.removeLast();
      if (out.contains(p)) continue;
      out.add(p);
      stack.addAll(_children[p] ?? const []);
    }
    return out;
  }

  /// The shells under a driver [root] (found through its non-shell
  /// children, which stay), with everything they run.
  List<int> toolTrees(int root) {
    final out = <int>[];
    final seen = <int>{root};
    final stack = [...?_children[root]];
    while (stack.isNotEmpty) {
      final p = stack.removeLast();
      if (!seen.add(p)) continue;
      if (rows[p]?.isShell ?? false) {
        out.addAll([p, ...descendants(p)]);
      } else {
        stack.addAll(_children[p] ?? const []);
      }
    }
    return out;
  }

  /// The processes whose working directory decides ownership: orphans
  /// without a visible tag.
  List<int> needsCwd() => [
    for (final p in orphans)
      if (rows[p]!.tag == null) p,
  ];

  /// [pid] and the processes it descends from.
  Set<int> ancestry(int pid) {
    final out = <int>{};
    int? p = pid;
    while (p != null && p > 0 && out.add(p)) {
      p = rows[p]?.ppid;
    }
    return out;
  }

  /// What to signal for session [tag]: everything under shells whose tree
  /// carries its tag (not the shells), the [toolTrees] of its driver
  /// [roots], processes carrying its tag wherever their parent is (the top of
  /// each tagged tree, with its children), and orphaned processes it started
  /// whose environment is hidden but whose folder is the session's.
  /// [cwds] maps pids from [needsCwd] to working directories.
  ///
  /// Never: the driver roots and the rest of their trees (the CLI, its MCP and
  /// LSP servers), the tmux shells themselves, [spared] processes and their trees
  /// (the session's helpers the app runs: language and MCP servers), [self] and
  /// what it descends from (the app), and processes of another EveryAI still
  /// running ([appTag] differs and that app's pid is in the table).
  List<int> sessionProcesses({
    required String tag,
    required String workingDir,
    required bool ownsDir,
    Map<int, String> cwds = const {},
    Set<int> roots = const {},
    Set<int> spared = const {},
    int? self,
    String? appTag,
  }) {
    bool inDir(int pid) => switch (cwds[pid]) {
      final String c => c == workingDir || c.startsWith(workingDir.endsWith('/') ? workingDir : '$workingDir/'),
      null => false,
    };
    // A visible tag anywhere in a tree settles whose it is.
    String? treeTag(int root) {
      for (final p in [root, ...descendants(root)]) {
        if (rows[p]?.tag case final t?) return t;
      }
      return null;
    }

    bool tagged(ProcessRow r) => r.tag == tag || r.owner == 'session:$tag';
    bool otherApp(ProcessRow r) {
      final a = r.app;
      if (a == null || appTag == null || a == appTag) return false;
      final i = a.indexOf(':');
      final other = i <= 0 ? null : int.tryParse(a.substring(0, i));
      return other != null && rows.containsKey(other);
    }

    final tools = {for (final root in roots) ...toolTrees(root)};
    final protected = <int>{
      for (final root in roots)
        if (rows.containsKey(root)) ...[root, ...descendants(root)],
      for (final h in spared)
        if (rows.containsKey(h)) ...[h, ...descendants(h)],
    }..removeAll(tools);
    final out = <int>{};
    final tmuxShells = shells;
    for (final shell in tmuxShells) {
      if (treeTag(shell) == tag) out.addAll(descendants(shell));
    }
    out.addAll(tools);
    for (final r in rows.values) {
      if (!tagged(r) || otherApp(r)) continue;
      // The top of a tagged tree: its parent isn't the session's too.
      if (rows[r.ppid] case final parent? when tagged(parent)) continue;
      out.addAll([r.pid, ...descendants(r.pid)]);
    }
    for (final o in orphans) {
      final r = rows[o]!;
      if (r.tag == null && !r.envVisible && ownsDir && inDir(o)) out.addAll([o, ...descendants(o)]);
    }
    final app = self == null ? const <int>{} : ancestry(self);
    out.removeWhere(
      (p) =>
          roots.contains(p) ||
          protected.contains(p) ||
          tmuxShells.contains(p) ||
          app.contains(p) ||
          (rows[p]?.isTerminalHost ?? true),
    );
    return out.toList()..sort();
  }
}
