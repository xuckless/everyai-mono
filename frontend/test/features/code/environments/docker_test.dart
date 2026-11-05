// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import 'package:every_ai/features/code/environments/discovery.dart';
import 'package:every_ai/features/code/environments/path_maps.dart';
import 'package:flutter_test/flutter_test.dart';

import 'env_fakes.dart';

const _docker = '/usr/local/bin/docker';

final _contexts = [
  {'Name': 'default', 'Current': false, 'DockerEndpoint': 'unix:///var/run/docker.sock'},
  {'Name': 'desktop-linux', 'Current': true, 'DockerEndpoint': 'unix:///Users/a/.docker/run/docker.sock'},
  {'Name': 'desktop-alias', 'Current': false, 'DockerEndpoint': 'unix:///Users/a/.docker/run/docker.sock'},
].map(jsonEncode).join('\n');

final _inspect = jsonEncode([
  {
    'Id': 'aaaaaaaaaaaa1111',
    'Name': '/web',
    'State': {'Running': true},
    'Config': {
      'User': '',
      'Labels': {'com.docker.compose.project': 'shop,with,commas'},
    },
    'Mounts': [
      {'Type': 'bind', 'Source': '/Users/a/shop', 'Destination': '/app', 'RW': true},
      {'Type': 'volume', 'Name': 'data', 'Source': '/var/lib/docker/volumes/data', 'Destination': '/data'},
    ],
  },
  {
    'Id': 'bbbbbbbbbbbb2222',
    'Name': '/vsc-proj-123',
    'State': {'Running': true},
    'Config': {
      'Labels': {
        'devcontainer.local_folder': '/Users/a/proj',
        'devcontainer.config_file': '/Users/a/proj/.devcontainer/devcontainer.json',
        'devcontainer.metadata': jsonEncode([
          {'remoteUser': 'root'},
          {'remoteUser': 'vscode'},
          {'customizations': <String, Object?>{}},
        ]),
      },
    },
    'Mounts': [
      {'Type': 'bind', 'Source': '/Users/a/proj', 'Destination': '/workspaces/proj', 'RW': true},
    ],
  },
]);

void main() {
  test('contexts: the current first, one per endpoint', () {
    expect(parseDockerContexts(_contexts), ['desktop-linux', 'default']);
  });

  test('inspect: plain containers and dev containers', () {
    final envs = parseDockerInspect(_inspect, cli: _docker, context: 'desktop-linux', hostName: 'host.docker.internal');
    expect(
      [for (final e in envs) (e.id, e.label, e.container, e.user)],
      [
        ('docker:desktop-linux/web', 'web (Container)', 'aaaaaaaaaaaa', null),
        ('devcontainer:/Users/a/proj', 'proj (Dev container)', 'bbbbbbbbbbbb', 'vscode'),
      ],
    );
    final web = envs.first;
    expect(web.toEnvPath('/Users/a/shop/src/x.ts'), '/app/src/x.ts');
    expect(web.toEnvPath('/Users/a/shopping'), isNull);
    expect(web.toHostPath('/app'), '/Users/a/shop');
    expect(web.toHostPath('/data/x'), isNull);
    expect(web.hostUrl(Uri.parse('http://127.0.0.1:41/mcp')), Uri.parse('http://host.docker.internal:41/mcp'));
  });

  test('wrap: names in -e, values in docker\'s own environment', () {
    final dev = parseDockerInspect(_inspect, cli: _docker, context: 'desktop-linux')[1];
    final w = dev.wrap('claude', ['-p', 'a b'], cwd: '/workspaces/proj', env: {'TOKEN': 'secret'});
    expect(w.executable, _docker);
    expect(w.args, [
      '--context', 'desktop-linux', 'exec', '-i', '-u', 'vscode', '-w', '/workspaces/proj', //
      '-e', 'TOKEN', 'bbbbbbbbbbbb', 'claude', '-p', 'a b',
    ]);
    expect(w.args.join(' '), isNot(contains('secret')));
    expect(w.environment, {'TOKEN': 'secret'});
    expect(() => dev.wrap('x', const [], env: {'A=B': 'c'}), throwsArgumentError);
  });

  test('discovery runs ps and one inspect per context', () async {
    final runner = FakeRunner({
      '$_docker context ls --format {{json .}}': ok(_contexts),
      '$_docker --context desktop-linux ps -q': ok('aaaaaaaaaaaa\nbbbbbbbbbbbb\n'),
      '$_docker --context desktop-linux inspect aaaaaaaaaaaa bbbbbbbbbbbb': ok(_inspect),
      '$_docker --context default ps -q': ok('', code: 1),
    });
    final found = await discoverEnvironments(fakeIo(runner, clis: {'docker': _docker}));
    expect(
      [for (final e in found.environments) e.id],
      ['host', 'devcontainer:/Users/a/proj', 'docker:desktop-linux/web'],
    );
    expect(found.problems, isEmpty);
  });

  test("a daemon that isn't running is a problem, not an error", () async {
    final runner = FakeRunner({'$_docker ps -q': ok('', code: 1)});
    final found = await discoverEnvironments(fakeIo(runner, clis: {'docker': _docker}));
    expect(found.environments.length, 1);
    expect(found.problems['docker'], contains("isn't running"));
  });

  test('a project with a dev container that isn\'t running says so', () {
    final envs = parseDockerInspect(_inspect, cli: _docker);
    final files = {'/Users/a/proj/.devcontainer/devcontainer.json', '/Users/a/other/.devcontainer.json'};
    expect(devcontainerProblem('/Users/a/proj', envs, exists: files.contains), isNull);
    expect(devcontainerProblem('/Users/a/other', envs, exists: files.contains), contains("isn't running"));
    expect(devcontainerProblem('/Users/a/plain', envs, exists: files.contains), isNull);
  });

  test('MountMap: longest prefix, whole segments, both ways', () {
    const m = MountMap([
      (host: '/Users/a', env: '/home/a', writable: false),
      (host: '/Users/a/code', env: '/code', writable: true),
      (host: '/', env: '/host', writable: false),
    ]);
    expect(m.toEnv('/Users/a/code/x'), '/code/x');
    expect(m.toEnv('/Users/a/codex'), '/home/a/codex');
    expect(m.toEnv('/etc/hosts'), '/host/etc/hosts');
    expect(m.toHost('/code'), '/Users/a/code');
    expect(m.toHost('/host/etc'), '/etc');
    expect(m.toHost('/opt'), isNull);
    expect(m.writableAt('/Users/a/code/y'), isTrue);
    expect(m.writableAt('/Users/a/notes'), isFalse);
  });
}
