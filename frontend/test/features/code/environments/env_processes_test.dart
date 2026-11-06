// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:every_ai/features/code/environments/env_processes.dart';
import 'package:every_ai/features/code/environments/exec_env.dart';
import 'package:every_ai/features/code/harness/session_processes.dart' show sessionEnvVar;
import 'package:flutter_test/flutter_test.dart';

import 'env_fakes.dart';

// 1 is the bridge's relay (untagged); 10 the CLI; 11 a node child of it (an
// MCP server); 12 its tool shell running 13; 20 another session's CLI.
const _listing = '''
1 0 0 init
10 1 1 claude
11 10 1 node
12 10 1 bash
13 12 1 npm
20 1 0 codex
garbage line
''';

void main() {
  test('the lister prints one row per process, tagged from its environment', () {
    final t = parseTagged(_listing, 's1');
    expect(t.rows.keys, [1, 10, 11, 12, 13, 20]);
    expect(t.rows[12]!.command, 'bash');
    expect(t.rows[12]!.isShell, isTrue);
    expect([for (final r in t.rows.values) r.tag], [null, 's1', 's1', 's1', 's1', null]);
    expect(tagLister, contains(r't="$1=$2"'));
  });

  test('Stop spares the CLI and its other children, and ends what its shells run', () {
    expect(insideTargets(parseTagged(_listing, 's1'), 's1', toolsOnly: true), [12, 13]);
  });

  test('a closed session ends every tagged process', () {
    expect(insideTargets(parseTagged(_listing, 's1'), 's1'), [10, 11, 12, 13]);
  });

  test('lists, then signals, through the bridge; the tag is only an argument', () async {
    final env = FakeEnv();
    final calls = <List<String>>[];
    final pids = await endInside(
      env,
      's1; rm -rf ~',
      toolsOnly: true,
      run: (exe, args, {timeout = Duration.zero, environment = const {}}) async {
        calls.add([exe, ...args]);
        return calls.length == 1 ? ok(_listing) : ok('');
      },
    );
    expect(env.wraps.first.executable, '/bin/sh');
    expect(env.wraps.first.args, ['-c', tagLister, 'sh', sessionEnvVar, 's1; rm -rf ~']);
    expect(pids, [12, 13]);
    expect(calls[1], ['/usr/bin/bridge', '/bin/sh', '-c', contains('kill -TERM'), 'sh', '12', '13']);
  });

  test("one CLI's end looks for its own marker, not the session's tag", () async {
    final env = FakeEnv();
    await endInside(
      env,
      'p1',
      variable: procEnvVar,
      run: (exe, args, {timeout = Duration.zero, environment = const {}}) async => ok(''),
    );
    expect(env.wraps.first.args, ['-c', tagLister, 'sh', procEnvVar, 'p1']);
  });

  test('nothing runs for the host, or when the list fails', () async {
    var ran = 0;
    Future<({int code, List<int> stdout})?> run(
      String exe,
      List<String> args, {
      Duration timeout = Duration.zero,
      Map<String, String> environment = const {},
    }) async {
      ran++;
      return null;
    }

    expect(await endInside(HostEnv.instance, 's1', run: run), isEmpty);
    expect(ran, 0);
    expect(await endInside(FakeEnv(), 's1', run: run), isEmpty);
    expect(ran, 1);
  });
}
