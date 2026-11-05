// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/features/code/environments/bridges.dart';
import 'package:every_ai/features/code/environments/discovery.dart';
import 'package:every_ai/features/code/environments/environment_providers.dart';
import 'package:every_ai/features/code/environments/exec_env.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'env_fakes.dart';

void main() {
  ProviderContainer container(FakeRunner runner, Map<String, String> clis, {List<SshRemote> ssh = const []}) {
    final c = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(Preferences.inMemory({sshRemotesKey: encodeSshRemotes(ssh)})),
        environmentIoProvider.overrideWithValue(fakeIo(runner, clis: clis)),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('the host first, then containers, VMs and ssh, whatever answers first', () async {
    final runner = FakeRunner({
      '/d ps -q': ok('aaaaaaaaaaaa\n'),
      '/d inspect aaaaaaaaaaaa': ok(
        jsonEncode([
          {'Id': 'aaaaaaaaaaaa', 'Name': '/web'},
        ]),
      ),
      '/l list --json': ok(jsonEncode({'name': 'default', 'status': 'Running'})),
    });
    final c = container(runner, {'docker': '/d', 'limactl': '/l', 'ssh': '/s'}, ssh: [const SshRemote.alias('box')]);
    final all = await c.read(environmentsProvider.future);
    expect(
      [for (final e in all) (e.id, e.kind)],
      [
        ('host', EnvKind.host),
        ('docker:web', EnvKind.container),
        ('lima:default', EnvKind.vm),
        ('ssh:box', EnvKind.ssh),
      ],
    );
    // context ls answered nothing, so the current context is used as is.
    expect(runner.calls, contains('/d context ls --format {{json .}}'));
  });

  test("a kind whose CLI isn't here is never run", () async {
    final runner = FakeRunner({});
    final c = container(runner, {});
    expect(await c.read(environmentsProvider.future), [HostEnv.instance]);
    expect(runner.calls, isEmpty);
    expect((await c.read(environmentDiscoveryProvider.future)).problems, isEmpty);
  });

  test("one failing kind doesn't hide the others", () async {
    final runner = FakeRunner({
      '/l list --json': ok(jsonEncode({'name': 'default', 'status': 'Running'})),
    });
    final c = container(
      runner,
      {'docker': '/d', 'limactl': '/l', 'multipass': '/m'},
      ssh: [const SshRemote.alias('x')],
    );
    final found = await c.read(environmentDiscoveryProvider.future);
    expect([for (final e in found.environments) e.id], ['host', 'lima:default']);
    expect(found.problems.keys.toSet(), {'docker', 'multipass', 'ssh'});
    expect(found.problems['ssh'], contains("ssh isn't installed"));
  });

  test('environmentById is null for a gone id, never the host', () {
    const all = [HostEnv.instance, LimaEnv(cli: '/l', name: 'dev', home: '/h')];
    expect(environmentById(all, 'lima:dev')?.label, 'dev (Lima)');
    expect(environmentById(all, 'host'), HostEnv.instance);
    expect(environmentById(all, 'wsl:Ubuntu'), isNull);
  });

  test('the host wraps nothing', () {
    final w = HostEnv.instance.wrap('git', ['status'], cwd: '/p', env: {'K': 'v'});
    expect(w.executable, 'git');
    expect(w.args, ['status']);
    expect(w.environment, {'K': 'v'});
    expect(HostEnv.instance.hostUrl(Uri.parse('http://127.0.0.1:1')), Uri.parse('http://127.0.0.1:1'));
  });
}
