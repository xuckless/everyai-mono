// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';

import 'package:every_ai/features/code/harness/everyai/app_tools_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("a DevTools port the session didn't start is refused; its own is used", () async {
    // A process of its own listens, standing in for a browser with remote debugging on.
    final server = await Process.start('python3', [
      '-c',
      '''
import socket, time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(1)
print(s.getsockname()[1], flush=True); time.sleep(30)
''',
    ]);
    addTearDown(server.kill);
    final port = int.parse((await server.stdout.transform(const SystemEncoding().decoder).first).trim());
    final url = 'ws://127.0.0.1:$port/devtools/browser/x';
    Future<String> call(Set<int> pids) async => (await runAppTool(
      {'action': 'list', 'source': url},
      sessions: ['owner-test'],
      root: Directory.systemTemp.path,
      vision: false,
      fit: (t, _) => t,
      windowPids: () async => pids,
    )).text;

    expect(await call({}), contains("belongs to a program this session didn't start"));
    expect(await call({server.pid}), isNot(contains("didn't start")));
  }, skip: Platform.isWindows ? 'lsof' : null);
}
