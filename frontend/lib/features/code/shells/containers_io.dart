// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/foundation.dart' show debugPrint;

import '../../../core/process/supervisor.dart';
import '../harness/everyai/shell_io.dart' show ShellEnv;
import 'containers.dart';

/// The container CLIs to ask, in order (Docker Desktop, OrbStack and Colima all answer `docker`).
const _clis = ['docker', 'podman'];

/// A CLI found missing or not answering is skipped for this long.
final _quietUntil = <String, DateTime>{};

/// [cli] [args], bounded: a daemon that hangs is stopped (verified) at [timeout].
Future<RunResult> _run(String cli, List<String> args, Map<String, String> env, Duration timeout) =>
    ProcessSupervisor.instance.runBounded(
      cli,
      args,
      timeout: timeout,
      env: env,
      owner: const ProbeOwner('containers'),
      maxOutputBytes: 16 * 1024 * 1024,
      label: '$cli ${args.first}',
    );

Future<List<SessionContainer>> listSessionContainers({required String worktree, Set<String> hints = const {}}) async {
  final env = (await ShellEnv.load()).env;
  final out = <SessionContainer>[];
  for (final cli in _clis) {
    if (_quietUntil[cli] case final t? when DateTime.now().isBefore(t)) continue;
    void quiet(Object why) {
      // Not installed, no daemon, or it hangs: ask again later.
      debugPrint('$cli is not answering ($why); asked again in a minute.');
      _quietUntil[cli] = DateTime.now().add(const Duration(minutes: 1));
    }

    final ps = await _run(cli, const ['ps', '-q', '--no-trunc'], env, const Duration(seconds: 3));
    if (ps is! Finished || ps.code != 0) {
      quiet(ps is Finished ? 'exit ${ps.code}' : ps);
      continue;
    }
    final ids = ps.stdout.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
    if (ids.isEmpty) continue;
    final inspect = await _run(cli, ['inspect', ...ids], env, const Duration(seconds: 5));
    if (inspect is! Finished) {
      quiet(inspect);
      continue;
    }
    if (inspect.code != 0) continue;
    for (final c in sessionContainersIn(inspect.stdout, worktree: worktree, hints: hints, cli: cli)) {
      if (!out.any((o) => o.id == c.id)) out.add(c);
    }
  }
  return out;
}

Future<bool> stopContainer(SessionContainer c) async {
  final env = (await ShellEnv.load()).env;
  final r = await _run(c.cli, ['stop', c.id], env, const Duration(seconds: 30));
  if (r case Finished(code: 0)) return true;
  debugPrint("Couldn't stop container ${c.name}: $r");
  return false;
}
