// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';
import 'dart:io';

import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/features/code/environments/bridges.dart';
import 'package:every_ai/features/code/environments/environment_providers.dart';
import 'package:every_ai/features/code/environments/environment_scan.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

  test('a command missing from the output counts as not installed', () {
    final scan = parseScanOutput('\n__EVERYAI_SCAN__\nPATH\t/usr/bin\n', ['gemini'])!;
    expect(scan.found['gemini']!.installed, isFalse);
    expect(scan.wslRoot, isNull);
    expect(parseScanOutput('no marker', ['x']), isNull);
  });

  test('no answer, no shell, ssh refused, and a stopped VM', () async {
    final none = await scanEnvironment(_lima, commands: ['claude'], run: FakeRunner({}).call);
    expect(none.problem, contains("didn't answer"));
    final broken = await scanEnvironment(
      _lima,
      commands: ['claude'],
      run: FakeRunner({
        _scanKey(['claude']): ok('sh: not found', code: 127),
      }).call,
    );
    expect(broken.problem, contains('exit code 127'));
    const ssh = SshEnv(cli: '/s', remote: SshRemote.alias('box'));
    final refused = await scanEnvironment(
      ssh,
      commands: const [],
      run: (exe, args, {timeout = Duration.zero, environment = const {}}) async => ok('', code: 255),
    );
    expect(refused.problem, contains('Connect once from a terminal'));
    final stopped = await scanEnvironment(
      const LimaEnv(cli: '/l', name: 'old', home: '/Users/a', running: false),
      run: FakeRunner({}).call,
    );
    expect(stopped.problem, contains('is stopped'));
  });

  test('a stopped WSL distro is scanned anyway: wsl.exe starts it', () async {
    const wsl = WslEnv(cli: 'C:/wsl.exe', distro: 'Ubuntu', running: false);
    final key = ['C:/wsl.exe', '-d', 'Ubuntu', '--exec', '/bin/sh', '-c', scanBootstrap, 'sh', scanProbe, 'claude'];
    final scan = await scanEnvironment(wsl, commands: ['claude'], run: FakeRunner({key.join(' '): ok(_output)}).call);
    expect(scan.problem, isNull);
    expect(scan.found['claude']!.installed, isTrue);
  });

  test("a CLI found only on a Windows drive isn't an install inside WSL", () {
    final scan = parseScanOutput(
      '\n__EVERYAI_SCAN__\nWINCLI\tcodex\t/mnt/c/Users/me/AppData/Roaming/npm/codex\nCLI\tcodex\t\t\n',
      ['codex'],
    )!;
    expect(scan.found['codex']!.installed, isFalse);
    expect(scan.found['codex']!.problem, contains('Only the Windows install'));
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

  test('a real /bin/sh: fish falls back to sh, and names are never run as code', () {
    final r = Process.runSync(
      '/bin/sh',
      ['-c', scanBootstrap, 'sh', scanProbe, r'$(echo pwned)', 'sh'],
      environment: {'SHELL': '/usr/local/bin/fish'},
    );
    final scan = parseScanOutput(r.stdout as String, [r'$(echo pwned)', 'sh'])!;
    expect(scan.found[r'$(echo pwned)']!.installed, isFalse);
    expect(scan.found['sh']!.installed, isTrue);
    expect(r.stdout as String, contains('CLI\t\$(echo pwned)\t'));
  }, skip: Platform.isWindows);

  test('the scan is kept per environment until invalidated', () async {
    const ps = '/d --context c ps -q';
    final inspect = jsonEncode([
      {'Id': 'cafecafecafe', 'Name': '/web'},
    ]);
    final scanKey = [
      '/d',
      '--context',
      'c',
      'exec',
      '-i',
      'cafecafecafe',
      '/bin/sh',
      '-c',
      scanBootstrap,
      'sh',
      scanProbe,
      'claude', //
    ].join(' ');
    final runner = FakeRunner({
      '/d context ls --format {{json .}}': ok(jsonEncode({'Name': 'c', 'Current': true})),
      ps: ok('cafecafecafe\n'),
      '/d --context c inspect cafecafecafe': ok(inspect),
      scanKey: ok(_output),
    });
    final c = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(Preferences.inMemory()),
        environmentIoProvider.overrideWithValue(fakeIo(runner, clis: {'docker': '/d'})),
        environmentScanCommandsProvider.overrideWithValue(const ['claude']),
      ],
    );
    addTearDown(c.dispose);
    final first = await c.read(environmentScanProvider('docker:c/web').future);
    await c.read(environmentScanProvider('docker:c/web').future);
    expect(first.found['claude']!.installed, isTrue);
    expect(runner.calls.where((k) => k == scanKey).length, 1);
    c.invalidate(environmentScanProvider('docker:c/web'));
    await c.read(environmentScanProvider('docker:c/web').future);
    expect(runner.calls.where((k) => k == scanKey).length, 2);
    final gone = await c.read(environmentScanProvider('docker:c/gone').future);
    expect(gone.problem, contains("isn't here"));
  });
}
