// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/features/code/environments/bridges.dart';
import 'package:every_ai/features/code/environments/discovery.dart';
import 'package:every_ai/features/code/environments/environment_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sshConfigHosts: names, patterns skipped, one level of Include', () {
    const config = '''
# work
Host box devbox.lan
  HostName 10.0.0.2
host = gpu
Host *.internal !secret ?x
Include config.d/*
Include /etc/ssh/extra
''';
    final files = {
      '/Users/a/.ssh/config.d/b': 'Host from-include\nInclude deeper\n',
      '/Users/a/.ssh/config.d/a': 'HOST box\n',
      '/etc/ssh/extra': 'Host extra',
      '/Users/a/.ssh/deeper': 'Host too-deep',
    };
    final hosts = sshConfigHosts(
      config,
      read: (p) => files[p],
      list: (d) => d == '/Users/a/.ssh/config.d' ? ['b', 'a'] : const [],
      sshDir: '/Users/a/.ssh',
      home: '/Users/a',
    );
    expect(hosts, ['box', 'devbox.lan', 'gpu', 'from-include', 'extra']);
  });

  test('remotes: problems, keys and the Preferences round trip', () {
    expect(const SshRemote.alias('-oProxyCommand=x').problem, isNotNull);
    expect(const SshRemote.host(user: 'me', host: 'a b').problem, isNotNull);
    expect(const SshRemote.host(user: 'me', host: 'h', port: 70000).problem, isNotNull);
    const remotes = [SshRemote.alias('box'), SshRemote.host(user: 'me', host: 'example.com', port: 2222)];
    expect(readSshRemotes(encodeSshRemotes(remotes)), remotes);
    expect(readSshRemotes('not json'), isEmpty);

    final prefs = Preferences.inMemory();
    final c = ProviderContainer(overrides: [preferencesProvider.overrideWithValue(prefs)]);
    addTearDown(c.dispose);
    final n = c.read(sshRemotesProvider.notifier);
    n.add(remotes[1]);
    n.add(remotes[1]);
    n.add(const SshRemote.alias('-bad'));
    expect(c.read(sshRemotesProvider), [remotes[1]]);
    expect(readSshRemotes(prefs[sshRemotesKey]), [remotes[1]]);
    n.remove(remotes[1]);
    expect(readSshRemotes(prefs[sshRemotesKey]), isEmpty);
  });

  test('wrap: one quoted remote command, BatchMode and a connect timeout', () {
    const env = SshEnv(
      cli: '/usr/bin/ssh',
      remote: SshRemote.host(user: 'me', host: 'example.com', port: 2222),
    );
    expect(env.id, 'ssh:me@example.com:2222');
    expect(env.label, 'example.com (SSH)');
    final w = env.wrap('claude', ['-p', r"it's $HOME"], cwd: '/srv/my app', env: {'K': 'v w'});
    expect(w.args, [
      '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', '-p', '2222', '--', 'me@example.com', //
      r"cd '/srv/my app' && exec env 'K=v w' claude -p 'it'\''s $HOME'",
    ]);
    expect(env.toEnvPath('/x'), isNull);
    expect(env.toHostPath('/x'), isNull);
    expect(env.hostUrl(Uri.parse('http://127.0.0.1:1')), isNull);
    expect(
      () => const SshEnv(cli: '/usr/bin/ssh', remote: SshRemote.alias('-oProxyCommand=x')).wrap('ls', const []),
      throwsArgumentError,
    );
  });
}
