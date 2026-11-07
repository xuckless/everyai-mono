import 'dart:io';

import 'package:every_ai/features/code/settings/settings_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('quick writes to one layer run in turn, so none is lost', () async {
    final dir = await Directory.systemTemp.createTemp('layer');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/settings.json';
    await Future.wait([
      for (var i = 0; i < 5; i++) writeLayer(path, (raw) => {...raw, 'k$i': i}),
    ]);
    expect(await readLayer(path), {'k0': 0, 'k1': 1, 'k2': 2, 'k3': 3, 'k4': 4});
    expect(dir.listSync().where((f) => f.path.endsWith('.tmp')), isEmpty);
  });

  test('a failed edit leaves the next write working', () async {
    final dir = await Directory.systemTemp.createTemp('layer');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/settings.json';
    final bad = writeLayer(path, (_) => throw StateError('no'));
    final good = writeLayer(path, (raw) => {...raw, 'ok': true});
    await expectLater(bad, throwsStateError);
    expect(await good, {'ok': true});
  });
}
