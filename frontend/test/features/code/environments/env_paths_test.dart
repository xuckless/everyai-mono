// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:every_ai/features/code/drivers/driver_events.dart';
import 'package:every_ai/features/code/drivers/driver_policy.dart';
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
}
