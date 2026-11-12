// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:every_ai/core/process/supervisor.dart';
import 'package:every_ai/features/code/drivers/driver_process.dart';
import 'package:every_ai/features/code/environments/env_processes.dart' show procEnvVar;
import 'package:every_ai/features/code/harness/session_processes.dart' show sessionEnvVar;
import 'package:flutter_test/flutter_test.dart';

import 'env_fakes.dart';

void main() {
  late Directory tmp;
  late List<String> ended;
  final original = endInsideOf;
  final originalSup = ProcessSupervisor.instance;
  late ProcessSupervisor sup;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('env-spawn');
    ended = [];
    endInsideOf = (env, proc) async {
      ended.add('${env.id} $proc');
      return const Ended([]);
    };
    sup = ProcessSupervisor.instance = ProcessSupervisor.create(ledgerDir: '${tmp.path}/ledger');
  });
  tearDown(() async {
    endInsideOf = original;
    insidePathOf = null;
    // Every bridge these tests started was closed (or ended): none left running.
    expect([
      for (final c in sup.children)
        if (c.state.live) c.spec.label,
    ], isEmpty);
    await sup.stopAll();
    ProcessSupervisor.instance = originalSup;
    tmp.deleteSync(recursive: true);
  });

  // The "bridge" prints what it was asked to run, then echoes stdin.
  FakeEnv echoBridge() => FakeEnv(
    wrapWith: (exe, args, cwd, env) => (
      executable: '/bin/sh',
      args: ['-c', r'echo "run $*"; exec cat', 'sh', '--cd', cwd!, exe, ...args],
      environment: env,
    ),
  );

  test('starts the bridge with the command inside, and the tag goes inside', () async {
    final env = echoBridge();
    final p = await spawnDriver(
      executable: '/env/bin/claude',
      args: ['-p', 'x y'],
      cwd: '/env/project',
      sessionTag: 's1',
      logPath: '${tmp.path}/logs/s1.log',
      env: {'K': 'v'},
      execEnv: env,
    );
    final first = p.lines.first;
    expect(await first, 'run --cd /env/project /env/bin/claude -p x y');
    final proc = env.wraps.single.env[procEnvVar]!;
    expect(env.wraps.single.env, {'K': 'v', sessionEnvVar: 's1', procEnvVar: proc});
    // The bridge ran from the log folder, made before it started.
    expect(Directory('${tmp.path}/logs').existsSync(), isTrue);
    final echoed = p.lines.first;
    p.send('hello');
    expect(await echoed, 'hello');
    await p.close();
    expect(ended, ['wsl:Ubuntu $proc']);
  });

  test("closing one CLI ends only what it runs, not the session's other CLIs under the same tag", () async {
    final env = echoBridge();
    Future<DriverProcess> start() => spawnDriver(
      executable: '/env/bin/claude',
      args: const [],
      cwd: '/env/p',
      sessionTag: 's1',
      logPath: '${tmp.path}/s1.log',
      execEnv: env,
    );
    final lead = await start();
    final probe = await start();
    final (leadProc, probeProc) = (env.wraps[0].env[procEnvVar]!, env.wraps[1].env[procEnvVar]!);
    expect(leadProc, isNot(probeProc));
    await probe.close();
    expect(ended, ['wsl:Ubuntu $probeProc']);
    await lead.close();
    expect(ended, ['wsl:Ubuntu $probeProc', 'wsl:Ubuntu $leadProc']);
  });

  test('the app quitting ends the processes inside too', () async {
    await spawnDriver(
      executable: 'claude',
      args: const [],
      cwd: '/env/p',
      sessionTag: 's2',
      logPath: '${tmp.path}/s2.log',
      execEnv: echoBridge(),
    );
    await closeAllDriverProcesses();
    expect(ended, hasLength(1));
  });
}
