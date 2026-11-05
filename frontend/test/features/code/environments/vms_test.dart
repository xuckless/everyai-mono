// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import 'package:every_ai/features/code/environments/bridges.dart';
import 'package:every_ai/features/code/environments/discovery.dart';
import 'package:every_ai/features/code/environments/path_maps.dart';
import 'package:flutter_test/flutter_test.dart';

import 'env_fakes.dart';

const _home = '/Users/a';

final _lima = [
  {'name': 'default', 'status': 'Running', 'dir': '$_home/.lima/default'},
  {
    'name': 'dev',
    'status': 'Running',
    'config': {
      'mounts': [
        {'location': '~', 'writable': false},
        {'location': '~/code', 'mountPoint': '/code', 'writable': true},
      ],
    },
  },
  {'name': 'old', 'status': 'Stopped'},
  {'name': 'colima', 'status': 'Running'},
].map(jsonEncode).join('\n');

void main() {
  test('Lima: running and stopped, colima left out, read-only home noted', () {
    final envs = parseLimaList(_lima, cli: '/opt/homebrew/bin/limactl', home: _home);
    expect(
      [for (final e in envs) (e.id, e.label, e.running)],
      [('lima:default', 'default (Lima)', true), ('lima:dev', 'dev (Lima)', true), ('lima:old', 'old (Lima)', false)],
    );
    expect(envs[0].note, contains('read-only'));
    expect(envs[0].toEnvPath('$_home/p'), '$_home/p');
    expect(envs[1].toEnvPath('$_home/code/p'), '/code/p');
    expect(envs[1].mounts.writableAt('$_home/code/p'), isTrue);
    final w = envs[0].wrap('claude', ['-p', 'a b'], cwd: '$_home/p q', env: {'K': 'v'});
    expect(w.args, ['shell', '--workdir', '$_home/p q', 'default', 'env', 'K=v', 'claude', '-p', 'a b']);
    expect(envs[0].wrap('ls', const []).args, ['shell', 'default', 'ls']);
    expect(envs[0].hostUrl(Uri.parse('http://localhost:5/x')), Uri.parse('http://host.lima.internal:5/x'));
  });

  test('OrbStack: JSON, the plain table, and its paths', () {
    expect(
      parseOrbList(
        jsonEncode([
          {'name': 'ubuntu', 'state': 'running'},
          {'name': 'arch', 'state': 'stopped'},
        ]),
      ),
      [('ubuntu', true), ('arch', false)],
    );
    expect(parseOrbList('NAME    STATE    DISTRO  VERSION  ARCH\nubuntu  running  ubuntu  noble    arm64\n'), [
      ('ubuntu', true),
    ]);
    const orb = OrbEnv(cli: '/usr/local/bin/orb', machine: 'ubuntu', home: _home);
    expect(orb.toEnvPath('$_home/p'), '$_home/p');
    expect(orb.toEnvPath('/opt/x'), '/mnt/mac/opt/x');
    expect(orb.toEnvPath('$_home/OrbStack/ubuntu/home/u'), '/home/u');
    expect(orb.toHostPath('/home/u'), '$_home/OrbStack/ubuntu/home/u');
    expect(orb.toHostPath('/mnt/mac/opt/x'), '/opt/x');
    final w = orb.wrap('claude', ['a b'], cwd: '/home/u/p', env: {'K': 'v'});
    expect(w.args, ['-m', 'ubuntu', 'sh', '-c', "cd /home/u/p && exec env 'K=v' claude 'a b'"]);
    const viaCtl = OrbEnv(cli: '/usr/local/bin/orbctl', machine: 'ubuntu', home: _home, viaOrbctl: true);
    expect(viaCtl.wrap('ls', const []).args, ['run', '-m', 'ubuntu', 'sh', '-c', 'exec ls']);
  });

  test('Multipass: list, mounts from info, and wrap', () async {
    const cli = '/usr/local/bin/multipass';
    final list = jsonEncode({
      'list': [
        {'name': 'primary', 'state': 'Running'},
        {'name': 'spare', 'state': 'Stopped'},
      ],
    });
    final info = jsonEncode({
      'errors': <Object>[],
      'info': {
        'primary': {
          'state': 'Running',
          'mounts': {
            '/home/ubuntu/code': {'source_path': '$_home/code', 'gid_mappings': <Object>[]},
          },
        },
      },
    });
    final runner = FakeRunner({'$cli list --format json': ok(list), '$cli info --format json primary': ok(info)});
    final found = await discoverEnvironments(fakeIo(runner, clis: {'multipass': cli}));
    final vms = found.environments.whereType<MultipassEnv>().toList();
    expect([for (final e in vms) (e.id, e.running)], [('multipass:primary', true), ('multipass:spare', false)]);
    expect(vms.first.toEnvPath('$_home/code/x'), '/home/ubuntu/code/x');
    expect(vms.first.wrap('claude', ['a'], cwd: '/home/ubuntu/code', env: {'K': 'v'}).args, [
      'exec', 'primary', '--working-directory', '/home/ubuntu/code', '--', 'env', 'K=v', 'claude', 'a', //
    ]);
    expect(vms.first.hostUrl(Uri.parse('http://127.0.0.1:1')), isNull);
  });

  test('Colima: profiles and wrap', () {
    final text = [
      {'name': 'default', 'status': 'Running', 'runtime': 'docker'},
      {'name': 'k8s', 'status': 'Stopped', 'runtime': 'containerd'},
    ].map(jsonEncode).join('\n');
    expect(parseColimaList(text), [('default', true), ('k8s', false)]);
    const c = ColimaEnv(cli: '/opt/homebrew/bin/colima', profile: 'default', home: _home);
    expect(c.wrap('ls', ['-la'], cwd: '$_home/p').args, [
      'ssh',
      '-p',
      'default',
      '--',
      'sh',
      '-c',
      'cd $_home/p && exec ls -la',
    ]);
    expect(c.toEnvPath('$_home/p'), '$_home/p');
    expect(c.toEnvPath('/opt'), isNull);
  });

  test('VM kinds run only when their CLI is found, and in a fixed order', () async {
    final runner = FakeRunner({
      '/l list --json': ok(_lima),
      '/c list --json': ok(jsonEncode({'name': 'default', 'status': 'Running'})),
    });
    final found = await discoverEnvironments(fakeIo(runner, clis: {'limactl': '/l', 'colima': '/c'}));
    expect(runner.calls.toSet(), {'/l list --json', '/c list --json'});
    expect(
      [for (final e in found.environments) e.id],
      [
        'host', 'lima:default', 'lima:dev', 'lima:old', 'colima:default', //
      ],
    );
  });

  test('a CLI that answers garbage gives a problem for its kind only', () async {
    final runner = FakeRunner({'/l list --json': ok('', code: 1), '/c list --json': ok('')});
    final found = await discoverEnvironments(fakeIo(runner, clis: {'limactl': '/l', 'colima': '/c'}));
    expect(found.problems.keys, ['lima']);
    expect(const MountMap([]).toEnv('/x'), isNull);
  });
}
