// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:every_ai/features/code/drivers/driver_events.dart';
import 'package:every_ai/features/code/domain/permissions.dart';
import 'package:every_ai/features/code/drivers/driver_policy.dart';
import 'package:every_ai/features/code/environments/bridges.dart';
import 'package:every_ai/features/code/environments/env_paths.dart';
import 'package:flutter_test/flutter_test.dart';

import 'env_fakes.dart';

void main() {
  final env = FakeEnv();

  test('paths come back as host paths', () {
    final c = actionEvent(
      id: 'a',
      toolName: 'Edit',
      kind: 'FileEditorAction',
      args: {'command': 'edit', 'path': '/env/p/a.dart', 'cwd': '/env/p', 'to': '/env/p/b.dart'},
    );
    final h = actionToHost(c, env.toHostPath);
    expect(h.str('path'), '/host/p/a.dart');
    expect(h.str('cwd'), '/host/p');
    expect(h.str('to'), '/host/p/b.dart');
    expect((h.raw['action']! as Map)['path'], '/host/p/a.dart');
    expect(h.str('command'), 'edit');
    expect(autoDecidable(h), isTrue);
  });

  test('a patch keeps its list; paths with no host side stay as they were', () {
    final c = actionEvent(
      id: 'b',
      toolName: 'apply_patch',
      kind: 'ApplyPatchAction',
      args: {
        'paths': ['/env/p/x', 'rel/y', '/etc/z'],
      },
    );
    final h = actionToHost(c, env.toHostPath);
    expect(h.action['paths'], ['/host/p/x', 'rel/y', '/etc/z']);
    expect(autoDecidable(h), isTrue);
  });

  test('a call with nothing to map is the same call', () {
    final c = actionEvent(id: 'c', toolName: 'Bash', kind: 'TerminalAction', args: {'command': 'ls'});
    expect(actionToHost(c, env.toHostPath), same(c));
  });

  test("a path that maps to a Windows one stays the agent's, so an edit outside the project still asks", () {
    const ubuntu = WslEnv(cli: r'C:\Windows\System32\wsl.exe', distro: 'Ubuntu');
    for (final p in ['/mnt/c/Users/u/.ssh/authorized_keys', '/home/u/.bashrc']) {
      final c = actionEvent(id: p, toolName: 'Write', kind: 'FileEditorAction', args: {'command': 'create', 'path': p});
      final h = actionToHost(c, ubuntu.toHostPath);
      expect(h.str('path'), p);
      expect(editDangerReason(h.str('path'), workingDir: r'C:\Users\u\proj'), outsideProject);
    }
  });
}
