// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../../core/process/supervisor.dart' show Ended, KillOutcome, ScanFailed, Survived;
import '../drivers/short_run.dart' show logStop;
import '../harness/session_processes.dart' show ProcessRow, ProcessTable, sessionEnvVar;
import 'discovery.dart' show RunCommand;
import 'environment_io_stub.dart' if (dart.library.io) 'environment_io_io.dart' as io;
import 'exec_env.dart';

/// The variable that marks one CLI the app started inside an environment
/// (and what it runs), next to the session's `EVERYAI_SESSION`.
const procEnvVar = 'EVERYAI_PROC';

/// Run by `/bin/sh -c` inside an environment with a variable's name as `$1`
/// and a value as `$2` (`EVERYAI_SESSION` and a session's tag): prints `pid
/// ppid tagged name` for each process in `/proc` (tagged is 1 when its
/// environment holds `$1=$2`; only the user's own processes have a readable
/// one). A constant: the tag is only ever an argument. Needs a Linux `/proc`
/// (WSL, containers, Linux VMs and hosts).
const tagLister = r'''t="$1=$2"
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

/// Sends the signal named first (TERM, KILL) to the pids after it.
const _killScript = r's=$1; shift; kill -"$s" "$@" 2>/dev/null; exit 0';

/// How long [endInsideChecked] gives the processes after SIGTERM, and after SIGKILL (tests shorten them).
@visibleForTesting
Duration insideTermGrace = const Duration(milliseconds: 1500);
@visibleForTesting
Duration insideKillWait = const Duration(milliseconds: 500);

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

/// Ends what runs inside [env] under session [tag] (see [insideTargets]), or
/// with [variable] [procEnvVar] under one CLI's marker: one exec lists the
/// processes, a second signals them. The host's own process walk
/// (`killSessionProcesses`) can't see inside, and a bridge's death (docker
/// exec, ssh, wsl.exe) doesn't end the processes behind it. Returns the pids
/// signalled; none for the host or when the list fails. What survives is in the log ([endInsideChecked] says it).
Future<List<int>> endInside(
  ExecEnv env,
  String tag, {
  bool toolsOnly = false,
  RunCommand? run,
  String variable = sessionEnvVar,
}) async {
  final (targets, outcome) = await _endInside(env, tag, toolsOnly: toolsOnly, run: run, variable: variable);
  logStop('processes inside ${env.label} ($tag)', outcome);
  return targets;
}

/// [endInside], checked: SIGTERM, [insideTermGrace], a second look; SIGKILL to what is left, [insideKillWait], a
/// third look. [Ended] with the pids that ended, [Survived] with those still listed, or [ScanFailed] when a list
/// failed (never "nothing running"). Ended for the host, where nothing runs inside.
Future<KillOutcome> endInsideChecked(
  ExecEnv env,
  String tag, {
  bool toolsOnly = false,
  RunCommand? run,
  String variable = sessionEnvVar,
}) async => (await _endInside(env, tag, toolsOnly: toolsOnly, run: run, variable: variable)).$2;

Future<(List<int>, KillOutcome)> _endInside(
  ExecEnv env,
  String tag, {
  required bool toolsOnly,
  required RunCommand? run,
  required String variable,
}) async {
  if (env.isHost || tag.isEmpty) return (const <int>[], const Ended([]));
  final runner = run ?? io.platformEnvironmentIo().run;
  Future<ProcessTable?> list() async {
    final cmd = env.wrap('/bin/sh', ['-c', tagLister, 'sh', variable, tag]);
    final res = await runner(
      cmd.executable,
      cmd.args,
      timeout: const Duration(seconds: 10),
      environment: cmd.environment,
    );
    return res == null || res.code != 0 ? null : parseTagged(utf8.decode(res.stdout, allowMalformed: true), tag);
  }

  Future<void> signal(String sig, List<int> pids) async {
    final kill = env.wrap('/bin/sh', ['-c', _killScript, 'sh', sig, for (final p in pids) '$p']);
    await runner(kill.executable, kill.args, timeout: const Duration(seconds: 10), environment: kill.environment);
  }

  final first = await list();
  if (first == null) return (const <int>[], ScanFailed("couldn't list the processes inside ${env.label}"));
  final targets = insideTargets(first, tag, toolsOnly: toolsOnly);
  if (targets.isEmpty) return (const <int>[], const Ended([]));
  await signal('TERM', targets);
  await Future<void>.delayed(insideTermGrace);
  final second = await list();
  if (second == null) return (targets, ScanFailed("couldn't look again inside ${env.label} after SIGTERM"));
  final left = [
    for (final p in targets)
      if (second.rows.containsKey(p)) p,
  ];
  if (left.isEmpty) return (targets, Ended(targets));
  await signal('KILL', left);
  await Future<void>.delayed(insideKillWait);
  final third = await list();
  if (third == null) return (targets, ScanFailed("couldn't look again inside ${env.label} after SIGKILL"));
  final survived = [
    for (final p in left)
      if (third.rows.containsKey(p)) p,
  ];
  final ended = [
    for (final p in targets)
      if (!survived.contains(p)) p,
  ];
  if (survived.isEmpty) return (targets, Ended(ended));
  return (targets, Survived(survived, 'still running inside ${env.label} after SIGKILL', ended: ended));
}
