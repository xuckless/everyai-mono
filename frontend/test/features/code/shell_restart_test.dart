@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:every_ai/features/code/harness/everyai/shell_io.dart';
import 'package:every_ai/features/code/shells/shell_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a second Restart while one runs joins it, and the shell keeps its folder', () async {
    final tmp = await Directory.systemTemp.createTemp('restart');
    addTearDown(() => tmp.delete(recursive: true));
    final sub = Directory('${tmp.path}/sub')..createSync();
    final registry = ShellRegistry.forTest();
    final shell = SessionShell(
      root: tmp.path,
      sessionTag: 't',
      scratchDir: '${tmp.path}/.sh',
      ptySpawner: null,
      registry: registry,
    );
    shell.cwd = sub.path;
    final bg = await shell.start('sleep 30');
    shell.cwd = tmp.path;
    addTearDown(shell.killAll);

    final a = shell.restart(bg.id), b = shell.restart(bg.id);
    final (first, second) = (await a, await b);
    expect(identical(first, second), isTrue);
    expect(registry.of('t').where((e) => e.id == bg.id && e.running), hasLength(1));
    expect(first!.entry.cwd, sub.path);
    expect(shell.cwd, tmp.path);
  });
}
