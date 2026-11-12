// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:every_ai/features/code/environments/bridges.dart';
import 'package:every_ai/features/code/git/git_env.dart';
import 'package:every_ai/features/code/git/git_service_io.dart' as io;
import 'package:flutter_test/flutter_test.dart';

import 'env_fakes.dart';

void main() {
  tearDown(() => gitInsideOf = null);

  const ubuntu = WslEnv(cli: r'C:\Windows\System32\wsl.exe', distro: 'Ubuntu');

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

  test('host paths from inside keep the distro prefix the project was opened with', () {
    expect(hostLike(r'\\wsl.localhost\Ubuntu\home\u\p', r'\\wsl$\ubuntu\home\u\p'), r'\\wsl$\ubuntu\home\u\p');
    expect(
      hostLike(r'\\wsl.localhost\Ubuntu\home\u\wt', r'\\wsl.localhost\Ubuntu\home\u\p'),
      r'\\wsl.localhost\Ubuntu\home\u\wt',
    );
    expect(hostLike(r'\\wsl.localhost\Debian\x', r'\\wsl$\Ubuntu\p'), r'\\wsl.localhost\Debian\x');
    expect(hostLike(r'C:\code\p', r'\\wsl$\Ubuntu\p'), r'C:\code\p');
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
  });
}
