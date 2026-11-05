// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:every_ai/features/code/environments/bridges.dart';
import 'package:every_ai/features/code/environments/exec_env.dart';
import 'package:every_ai/features/code/git/git_env.dart';
import 'package:every_ai/features/code/git/git_service.dart';
import 'package:every_ai/features/code/git/git_service_io.dart' as io;
import 'package:flutter_test/flutter_test.dart';

import 'env_fakes.dart';

void main() {
  tearDown(() => gitInsideOf = null);

  const ubuntu = WslEnv(cli: r'C:\Windows\System32\wsl.exe', distro: 'Ubuntu');

  test("only a WSL distro's own files run git inside", () {
    expect(wslDistroOf(r'\\wsl.localhost\Ubuntu\home\u\p'), 'Ubuntu');
    expect(wslDistroOf(r'\\wsl$\Debian\srv'), 'Debian');
    expect(wslDistroOf(r'C:\code\p'), isNull);
    expect(gitRunsInside(ubuntu, r'\\wsl.localhost\Ubuntu\home\u\p'), isTrue);
    expect(gitRunsInside(ubuntu, r'C:\code\p'), isFalse);
    expect(gitRunsInside(FakeEnv(kind: EnvKind.container), r'\\wsl.localhost\Ubuntu\p'), isFalse);
  });

  test('git for a folder inside goes through the bridge, with -C and GIT_INDEX_FILE as the distro sees them', () async {
    gitInsideOf = (dir) async => (env: ubuntu, dataDir: r'\\wsl.localhost\Ubuntu\home\u\.local\share\everyai');
    final cmd = await io.gitCommand(
      'git',
      [
        '-C',
        r'\\wsl.localhost\Ubuntu\home\u\p',
        'worktree',
        'add',
        '-q',
        '-b',
        'everyai/s',
        r'\\wsl.localhost\Ubuntu\home\u\wt/s',
        'HEAD',
      ],
      env: {'GIT_INDEX_FILE': r'C:\Users\u\Temp\everyai-index1\index'},
    );
    expect(cmd.exe, ubuntu.cli);
    expect(cmd.args, [
      '-d',
      'Ubuntu',
      '--exec',
      'git',
      '-C',
      '/home/u/p',
      'worktree',
      'add',
      '-q',
      '-b',
      'everyai/s',
      '/home/u/wt/s',
      'HEAD',
    ]);
    expect(cmd.env, {'GIT_INDEX_FILE': '/mnt/c/Users/u/Temp/everyai-index1/index', 'WSLENV': 'GIT_INDEX_FILE/u'});
    expect(
      await gitDataDirInside(r'\\wsl.localhost\Ubuntu\home\u\p'),
      r'\\wsl.localhost\Ubuntu\home\u\.local\share\everyai',
    );
  });

  test("a folder on this computer's drives, or an environment that isn't WSL, keeps this computer's git", () async {
    gitInsideOf = (dir) async => (env: ubuntu, dataDir: '');
    final onC = await io.gitCommand('git', ['-C', r'C:\code\p', 'status']);
    expect(onC.exe, 'git');
    expect(onC.args, ['-C', r'C:\code\p', 'status']);
    gitInsideOf = (dir) async => (env: FakeEnv(kind: EnvKind.container), dataDir: '');
    final docker = await io.gitCommand('git', ['-C', r'\\wsl.localhost\Ubuntu\p', 'status']);
    expect(docker.exe, 'git');
    expect(await gitDataDirInside(r'\\wsl.localhost\Ubuntu\p'), isNull);
  });

  group('answers come back as host paths', () {
    late Directory tmp;
    late String real;
    const unc = '//wsl.localhost/Ubuntu';
    // A "distro" whose files are this machine's, seen from the host under a UNC-like prefix.
    final env = FakeEnv(
      hostRoot: unc,
      envRoot: '',
      wrapWith: (exe, args, cwd, e) => (executable: exe, args: args, environment: e),
    );

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('git-inside');
      real = tmp.resolveSymbolicLinksSync();
      for (final a in [
        ['init', '-q', '-b', 'main'],
        ['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '--allow-empty', '-m', 'x'],
        ['worktree', 'add', '-q', '$real/wt', '-b', 'side'],
      ]) {
        expect((await Process.run('git', a, workingDirectory: real)).exitCode, 0);
      }
      gitInsideOf = (dir) async => (env: env, dataDir: '$unc/home/u/.local/share/everyai');
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('repoRoot and worktrees', () async {
      expect(await GitService.repoRoot('$unc$real'), '$unc$real');
      expect(await GitService.worktrees('$unc$real'), ['$unc$real', '$unc$real/wt']);
    });

    test("a repository at the distro user's home isn't the project's", () async {
      final home = FakeEnv(
        hostRoot: unc,
        envRoot: '/home/u',
        wrapWith: (exe, args, cwd, e) => (executable: '/bin/sh', args: ['-c', r'echo /home/u', 'sh'], environment: e),
      );
      gitInsideOf = (dir) async => (env: home, dataDir: '');
      expect(await GitService.repoRoot('$unc/x'), isNull);
    });
  });
}
