// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';

import '../harness/everyai/shell_io.dart' show ShellEnv;
import 'containers.dart';

/// The container CLIs to ask, in order (Docker Desktop, OrbStack and Colima all answer `docker`).
const _clis = ['docker', 'podman'];

/// A CLI found missing or not answering is skipped for this long.
final _quietUntil = <String, DateTime>{};

Future<List<SessionContainer>> listSessionContainers({required String worktree, Set<String> hints = const {}}) async {
  final env = (await ShellEnv.load()).env;
  final out = <SessionContainer>[];
  for (final cli in _clis) {
    if (_quietUntil[cli] case final t? when DateTime.now().isBefore(t)) continue;
    try {
      final ps = await Process.run(cli, [
        'ps',
        '-q',
        '--no-trunc',
      ], environment: env).timeout(const Duration(seconds: 3));
      if (ps.exitCode != 0) {
        _quietUntil[cli] = DateTime.now().add(const Duration(minutes: 1));
        continue;
      }
      final ids = '${ps.stdout}'.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
      if (ids.isEmpty) continue;
      final inspect = await Process.run(cli, ['inspect', ...ids], environment: env).timeout(const Duration(seconds: 5));
      if (inspect.exitCode != 0) continue;
      for (final c in sessionContainersIn('${inspect.stdout}', worktree: worktree, hints: hints, cli: cli)) {
        if (!out.any((o) => o.id == c.id)) out.add(c);
      }
    } on Object {
      // Not installed (ProcessException) or the daemon hangs: ask again later.
      _quietUntil[cli] = DateTime.now().add(const Duration(minutes: 1));
    }
  }
  return out;
}

Future<bool> stopContainer(SessionContainer c) async {
  try {
    final env = (await ShellEnv.load()).env;
    final res = await Process.run(c.cli, ['stop', c.id], environment: env).timeout(const Duration(seconds: 30));
    return res.exitCode == 0;
  } on Object {
    return false;
  }
}
