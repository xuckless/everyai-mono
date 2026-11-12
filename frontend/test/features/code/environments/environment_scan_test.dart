// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';

import 'package:every_ai/features/code/environments/bridges.dart';
import 'package:every_ai/features/code/environments/environment_scan.dart';
import 'package:flutter_test/flutter_test.dart';

import 'env_fakes.dart';

const _lima = LimaEnv(cli: '/l', name: 'dev', home: '/Users/a');

const _output =
    'Welcome to Ubuntu 24.04\nbash: no job control in this shell\n'
    '\n__EVERYAI_SCAN__\n'
    'PATH\t/home/u/.nvm/versions/node/v22/bin:/usr/bin\n'
    'HOME\t/home/u\n'
    'OS\tLinux x86_64\n'
    'WSLROOT\t/mnt/c/\n'
    'GATEWAY\t172.20.0.1\n'
    'CLI\tclaude\t/home/u/.nvm/versions/node/v22/bin/claude\t2.1.0 (Claude Code)\r\n'
    'CLI\tcodex\t\t\n';

String _scanKey(List<String> commands) =>
    ['/l', 'shell', 'dev', '/bin/sh', '-c', scanBootstrap, 'sh', scanProbe, ...commands].join(' ');

void main() {
  test('one call through the bridge, the commands only as arguments', () async {
    final runner = FakeRunner({
      _scanKey(['claude', 'codex']): ok(_output),
    });
    final scan = await scanEnvironment(_lima, commands: ['claude', 'codex', 'bad name', 'a/b'], run: runner.call);
    expect(runner.calls, [
      _scanKey(['claude', 'codex']),
    ]);
    expect(scanBootstrap, isNot(contains('codex')));
    expect(scan.problem, isNull);
    expect(scan.path, '/home/u/.nvm/versions/node/v22/bin:/usr/bin');
    expect(scan.home, '/home/u');
    expect(scan.os, 'Linux x86_64');
    expect(scan.wslRoot, '/mnt/');
    expect(scan.hostAddress, '172.20.0.1');
    expect(scan.found['claude']!.installed, isTrue);
    expect(scan.found['claude']!.path, '/home/u/.nvm/versions/node/v22/bin/claude');
    expect(scan.found['claude']!.version, '2.1.0 (Claude Code)');
    expect(scan.found['codex']!.installed, isFalse);
  });

  test('a real /bin/sh: the probe skips PATH hits under the WSL drive root', () {
    final tmp = Directory.systemTemp.createTempSync('everyai-scan');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final bin = Directory('${tmp.path}/bin')..createSync();
    final winNpm = Directory('${tmp.path}/mnt/c/npm')..createSync(recursive: true);
    final home = Directory('${tmp.path}/home')..createSync();
    Directory('${home.path}/.local/bin').createSync(recursive: true);
    void script(String path, String body) {
      File(path).writeAsStringSync('#!/bin/sh\n$body\n');
      Process.runSync('chmod', ['+x', path]);
    }

    script('${bin.path}/wslpath', 'echo ${tmp.path}/mnt/c/');
    script('${winNpm.path}/codex', 'echo windows');
    script('${winNpm.path}/claude', 'echo windows');
    script('${home.path}/.local/bin/claude', 'echo 2.0 linux');
    final r = Process.runSync(
      '/bin/sh',
      ['-c', scanProbe, 'sh', 'codex', 'claude'],
      environment: {'PATH': '${bin.path}:${winNpm.path}:/usr/bin:/bin', 'HOME': home.path},
      includeParentEnvironment: false,
    );
    final scan = parseScanOutput(r.stdout as String, ['codex', 'claude'])!;
    expect(scan.wslRoot, '${tmp.path}/mnt/');
    expect(scan.found['codex']!.installed, isFalse);
    expect(scan.found['codex']!.problem, contains('${winNpm.path}/codex'));
    expect(scan.found['claude']!.path, '${home.path}/.local/bin/claude');
    expect(scan.found['claude']!.version, '2.0 linux');
  }, skip: Platform.isWindows);
}
