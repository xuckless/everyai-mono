import 'package:every_ai/features/code/git/git_guard.dart';
import 'package:flutter_test/flutter_test.dart';

GitConfigEntry _local(String key, String value) => (scope: 'local', key: key, value: value);
GitConfigEntry _global(String key, String value) => (scope: 'global', key: key, value: value);

void main() {
  test('every call turns hooks, fsmonitor, submodules, ext:: and signatures off', () {
    expect(guardFlags('/dev/null'), [
      '-c', 'core.hooksPath=/dev/null', '-c', 'core.fsmonitor=false', '-c', 'submodule.recurse=false', //
      '-c', 'protocol.ext.allow=never', '-c', 'safe.bareRepository=explicit', '-c', 'log.showSignature=false',
    ]);
  });

  test('the repository\'s program keys are overridden; the user\'s own values are used again', () {
    final guard = repoGuard([
      _global('gpg.program', '/opt/homebrew/bin/gpg'),
      _global('credential.helper', 'osxkeychain'),
      _global('credential.https://github.com.helper', '!gh auth git-credential'),
      _local('core.fsmonitor', './watch.sh'),
      _local('filter.s.smudge', './smudge.sh'),
      _local('merge.m.driver', './merge.sh %A'),
      _local('gpg.program', './gpg.sh'),
      _local('gpg.ssh.program', './sign.sh'),
      _local('core.sshcommand', './ssh.sh'),
      _local('core.gitproxy', './proxy.sh'),
      _local('credential.helper', '!./steal.sh'),
      // From a file .git/config includes: git reports it as local.
      _local('core.askpass', './ask.sh'),
    ]);
    expect(guard.refusal, isNull);
    expect(guard.args, [
      '-c', 'filter.s.smudge=', '-c', 'filter.s.required=false', //
      '-c', 'merge.m.driver=git merge-file %A %O %B',
      '-c', 'gpg.program=/opt/homebrew/bin/gpg',
      '-c', 'gpg.ssh.program=ssh-keygen',
      '-c', 'core.sshcommand=ssh',
      '-c', 'protocol.git.allow=never',
      '-c', 'core.askpass=',
      '-c', 'credential.helper=',
      '-c', 'credential.helper=osxkeychain',
      '-c', 'credential.https://github.com.helper=!gh auth git-credential',
    ]);
  });

  test('a filter that cleans files, or one dressed up as git-crypt, is blanked and storing files is refused', () {
    for (final entry in [
      _local('filter.x.clean', './x.sh'),
      _local('filter.x.process', './x.sh'),
      _local('filter.lfs.clean', 'git-lfs clean -- %f; ./x.sh'),
      _local('filter.git-crypt.clean', '"/tmp/git-crypt" clean'),
    ]) {
      final name = entry.key.split('.')[1];
      final guard = repoGuard([entry]);
      expect(guard.refusal, contains('filter "$name"'), reason: entry.value);
      expect(guard.args, [
        '-c', 'filter.$name.clean=', '-c', 'filter.$name.smudge=', '-c', 'filter.$name.process=', //
        '-c', 'filter.$name.required=false',
      ]);
      expect(blocksStoring(entry), isTrue);
    }
    expect([
      for (final c in ['add', 'commit', 'stash', 'apply']) storesFiles(c),
    ], everyElement(isTrue));
    expect(
      [
        for (final c in ['worktree', 'status', 'diff', 'restore', 'switch', 'read-tree']) storesFiles(c),
      ],
      [for (var i = 0; i < 6; i++) false],
    );
  });

  test('a filter, hook or merge driver named with "=" blocks every guarded call; the env form still reaches it', () {
    for (final entry in [
      _local('filter.x=y.smudge', 'sh -c evil'),
      _local('filter.x=y.clean', 'sh -c evil'),
      _local('hook.a=b.command', 'sh -c evil'),
      _local('merge.a=b.driver', 'sh -c evil'),
    ]) {
      final guard = repoGuard([entry]);
      expect(guard.block, contains('"="'), reason: entry.key);
    }
    expect(repoGuard([_local('filter.x.smudge', 'sh -c evil')]).block, isNull);
    final env = configEnvOf(repoGuard([_local('filter.x=y.smudge', 'evil')]).config, count: 2);
    expect(env['GIT_CONFIG_KEY_2'], 'filter.x=y.smudge');
    expect(env['GIT_CONFIG_VALUE_2'], '');
    expect(env['GIT_CONFIG_KEY_3'], 'filter.x=y.required');
    expect(env['GIT_CONFIG_COUNT'], '4');
  });
}
