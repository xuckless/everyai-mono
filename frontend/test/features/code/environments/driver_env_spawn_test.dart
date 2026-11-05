// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:every_ai/features/code/drivers/driver_process.dart';
import 'package:every_ai/features/code/environments/exec_env.dart';
import 'package:every_ai/features/code/harness/session_processes.dart' show sessionEnvVar;
import 'package:flutter_test/flutter_test.dart';

import 'env_fakes.dart';

void main() {
  late Directory tmp;
  late List<String> ended;
  final original = endInsideOf;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('env-spawn');
    ended = [];
    endInsideOf = (env, tag) async => ended.add('${env.id} $tag');
  });
  tearDown(() {
    endInsideOf = original;
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
    expect(env.wraps.single.env, {'K': 'v', sessionEnvVar: 's1'});
    // The bridge ran from the log folder, made before it started.
    expect(Directory('${tmp.path}/logs').existsSync(), isTrue);
    final echoed = p.lines.first;
    p.send('hello');
    expect(await echoed, 'hello');
    await p.close();
    expect(ended, ['wsl:Ubuntu s1']);
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
    expect(ended, ['wsl:Ubuntu s2']);
  });

  test('a bridge that exits on its own ends what it left inside', () async {
    final env = FakeEnv(
      wrapWith: (exe, args, cwd, e) => (executable: '/bin/sh', args: ['-c', 'exit 0'], environment: e),
    );
    final p = await spawnDriver(
      executable: 'claude',
      args: const [],
      cwd: '/env/p',
      sessionTag: 's3',
      logPath: '${tmp.path}/s3.log',
      execEnv: env,
    );
    await p.exitCode;
    await p.close();
    expect(ended, ['wsl:Ubuntu s3']);
  });

  test('the host runs the command itself', () async {
    final p = await spawnDriver(
      executable: '/bin/sh',
      args: ['-c', 'echo "\$$sessionEnvVar"'],
      cwd: tmp.path,
      sessionTag: 'h1',
      logPath: '${tmp.path}/h1.log',
      execEnv: HostEnv.instance,
    );
    expect(await p.lines.first, 'h1');
    await p.close();
    expect(ended, isEmpty);
  });
}
