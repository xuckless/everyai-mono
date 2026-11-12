// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:every_ai/core/process/supervisor.dart' show ScanFailed, Survived;
import 'package:every_ai/features/code/environments/env_processes.dart';
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
  setUp(() {
    insideTermGrace = Duration.zero;
    insideKillWait = Duration.zero;
  });

  test('Stop spares the CLI and its other children, and ends what its shells run', () {
    expect(insideTargets(parseTagged(_listing, 's1'), 's1', toolsOnly: true), [12, 13]);
  });

  test('a closed session ends every tagged process', () {
    expect(insideTargets(parseTagged(_listing, 's1'), 's1'), [10, 11, 12, 13]);
  });

  test('checked: what survives SIGTERM gets SIGKILL, and what survives that is reported', () async {
    final env = FakeEnv();
    final calls = <List<String>>[];
    final outcome = await endInsideChecked(
      env,
      's1',
      run: (exe, args, {timeout = Duration.zero, environment = const {}}) async {
        calls.add([exe, ...args]);
        // Lists: everything, then 10 (ignored TERM) still there, then 10 still there after KILL.
        return switch (calls.length) {
          1 => ok(_listing),
          3 || 5 => ok('10 1 1 claude\n'),
          _ => ok(''),
        };
      },
    );
    expect(calls[3], contains('KILL'));
    expect(calls[3].sublist(calls[3].length - 1), ['10']);
    expect(outcome, isA<Survived>().having((s) => s.pids, 'pids', [10]).having((s) => s.ended, 'ended', [11, 12, 13]));
  });

  test('checked: a list that fails is a failed scan, never "nothing running"', () async {
    final outcome = await endInsideChecked(
      FakeEnv(),
      's1',
      run: (exe, args, {timeout = Duration.zero, environment = const {}}) async => null,
    );
    expect(outcome, isA<ScanFailed>());
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
}
