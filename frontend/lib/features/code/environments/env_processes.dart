// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import '../harness/session_processes.dart' show ProcessRow, ProcessTable;
import 'discovery.dart' show RunCommand;
import 'environment_io_stub.dart' if (dart.library.io) 'environment_io_io.dart' as io;
import 'exec_env.dart';

/// Run by `/bin/sh -c` inside an environment with a session's tag as `$1`:
/// prints `pid ppid tagged name` for each process in `/proc` (tagged is 1
/// when its environment holds `EVERYAI_SESSION=<tag>`; only the user's own
/// processes have a readable one). A constant: the tag is only ever an
/// argument. Needs a Linux `/proc` (WSL, containers, Linux VMs and hosts).
const tagLister = r'''t="EVERYAI_SESSION=$1"
for d in /proc/[0-9]*; do
  p=${d#/proc/}
  [ "$p" = "$$" ] && continue
  [ -r "$d/status" ] || continue
  n=; pp=
  while read -r k v; do
    case $k in Name:) n=$v ;; PPid:) pp=$v ;; esac
  done < "$d/status"
  g=0
  if tr '\0' '\n' < "$d/environ" 2>/dev/null | grep -qxF "$t"; then g=1; fi
  printf '%s %s %s %s\n' "$p" "$pp" "$g" "$n"
done
''';

/// Sends SIGTERM to the pids after it.
const _killScript = r'kill -TERM "$@" 2>/dev/null; exit 0';

/// The process table [tagLister] printed, with [tag] on the tagged rows.
ProcessTable parseTagged(String out, String tag) {
  final line = RegExp(r'^(\d+) (\d+) ([01]) ?(.*)$');
  return ProcessTable([
    for (final l in const LineSplitter().convert(out))
      if (line.firstMatch(l.trimRight()) case final m?)
        ProcessRow(
          pid: int.parse(m.group(1)!),
          ppid: int.parse(m.group(2)!),
          command: m.group(4)!,
          tag: m.group(3) == '1' ? tag : null,
        ),
  ]);
}

/// The pids in [table] to end for session [tag]. Its roots are the tagged
/// processes whose parent isn't tagged: the CLIs the bridge started. With
/// [toolsOnly] (Stop) the roots stay and only what their shells run goes
/// ([ProcessTable.toolTrees], as on the host); otherwise (the session
/// closed) every tagged process.
List<int> insideTargets(ProcessTable table, String tag, {bool toolsOnly = false}) {
  final tagged = {
    for (final r in table.rows.values)
      if (r.tag == tag) r.pid,
  };
  if (!toolsOnly) return tagged.toList()..sort();
  final roots = {
    for (final p in tagged)
      if (!tagged.contains(table.rows[p]!.ppid)) p,
  };
  // Not sessionProcesses: inside, a bridge's CLI is often a child of pid 1, which that rule reads as an orphan
  // the session left (whole tree signalled). So a server the agent left to init outlives Stop; closing ends it.
  return {for (final r in roots) ...table.toolTrees(r)}.where((p) => !roots.contains(p)).toList()..sort();
}

/// Ends what runs inside [env] under session [tag] (see [insideTargets]):
/// one exec lists the processes, a second signals them. The host's own
/// process walk (`killSessionProcesses`) can't see inside, and a bridge's
/// death (docker exec, ssh, wsl.exe) doesn't end the processes behind it.
/// Returns the pids signalled; none for the host or when the list fails.
Future<List<int>> endInside(ExecEnv env, String tag, {bool toolsOnly = false, RunCommand? run}) async {
  if (env.isHost || tag.isEmpty) return const [];
  final runner = run ?? io.platformEnvironmentIo().run;
  final list = env.wrap('/bin/sh', ['-c', tagLister, 'sh', tag]);
  final res = await runner(
    list.executable,
    list.args,
    timeout: const Duration(seconds: 10),
    environment: list.environment,
  );
  if (res == null) return const [];
  final pids = insideTargets(
    parseTagged(utf8.decode(res.stdout, allowMalformed: true), tag),
    tag,
    toolsOnly: toolsOnly,
  );
  if (pids.isEmpty) return const [];
  final kill = env.wrap('/bin/sh', ['-c', _killScript, 'sh', for (final p in pids) '$p']);
  await runner(kill.executable, kill.args, timeout: const Duration(seconds: 10), environment: kill.environment);
  return pids;
}
