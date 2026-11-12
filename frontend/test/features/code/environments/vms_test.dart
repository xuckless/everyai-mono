// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import 'package:every_ai/features/code/environments/bridges.dart';
import 'package:every_ai/features/code/environments/discovery.dart';
import 'package:every_ai/features/code/environments/path_maps.dart';
import 'package:flutter_test/flutter_test.dart';

import 'env_fakes.dart';

const _home = '/Users/a';

void main() {
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

  test("a worktree under a read-only share, or outside every share, isn't writable inside", () {
    const lima = LimaEnv(
      cli: '/l',
      name: 'default',
      home: '/Users/a',
      mounts: MountMap([
        (host: '/Users/a', env: '/Users/a', writable: false),
        (host: '/tmp/lima', env: '/tmp/lima', writable: true),
      ]),
    );
    expect(lima.writableInside('/Users/a/Library/Application Support/x/worktrees'), isFalse);
    expect(lima.writableInside('/tmp/lima/w'), isTrue);
    expect(lima.writableInside('/opt/x'), isFalse);
    const colima = ColimaEnv(cli: '/c', profile: 'default', home: '/Users/a');
    expect(colima.writableInside('/Users/a/Library/x'), isTrue);
  });
}
