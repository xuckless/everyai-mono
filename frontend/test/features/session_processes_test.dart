import 'dart:convert';

import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/harness/openhands_harness.dart';
import 'package:every_ai/features/code/harness/session_processes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ProcessRow _row(int pid, int ppid, String cmd, {String? tag, bool env = true}) =>
    ProcessRow(pid: pid, ppid: ppid, command: cmd, tag: tag, envVisible: env);

void main() {
  const dir = '/w/session-a';
  // 10 agent-server bootloader → 11 server → shells 20 (session a), 30 (session b).
  final table = ProcessTable([
    _row(10, 1, '/app/Resources/agent-server --port 4000'),
    _row(11, 10, '/app/Resources/agent-server --port 4000'),
    _row(20, 11, '/bin/bash', env: false),
    _row(21, 20, 'python gen.py', tag: 'a'),
    _row(22, 21, '/bin/sleep 600', env: false),
    _row(23, 20, 'node server.js', tag: 'a'),
    _row(30, 11, '/bin/bash', env: false),
    _row(31, 30, 'python other.py', tag: 'b'),
    _row(40, 1, 'node orphan.js', tag: 'a'),
    _row(41, 1, '/bin/sleep 900', env: false),
    _row(42, 1, '/Applications/Editor.app/Editor', tag: null),
    _row(50, 1, 'tmux new-session', tag: 'a'),
  ]);

  test('finds the shells and orphans', () {
    expect(table.shells, unorderedEquals([20, 30]));
    expect(table.orphans, unorderedEquals([40, 41, 42]));
  });

  test("takes everything under the session's shell, never the shell or the server", () {
    final pids = table.sessionProcesses(tag: 'a', workingDir: dir, ownsDir: false);
    expect(pids, [21, 22, 23, 40]);
  });

  test("leaves other sessions' processes alone", () {
    expect(table.sessionProcesses(tag: 'b', workingDir: '/w/session-b', ownsDir: true), [31]);
  });

  test('untagged trees count by working directory', () {
    final t = ProcessTable([
      _row(11, 1, '/x/agent-server'),
      _row(20, 11, '/bin/bash', env: false),
      _row(21, 20, '/bin/sleep 600', env: false),
      _row(30, 11, '/bin/bash', env: false),
      _row(31, 30, '/bin/sleep 600', env: false),
      _row(41, 1, '/bin/sleep 900', env: false),
    ]);
    final cwds = {20: '$dir/lib', 30: '/w/session-b', 41: dir};
    expect(t.needsCwd(), unorderedEquals([20, 30, 41]));
    // An orphan counts only when the session has the directory to itself.
    // Shells and orphans count only when the session has the directory to itself.
    expect(t.sessionProcesses(tag: 'a', workingDir: dir, ownsDir: false, cwds: cwds), isEmpty);
    expect(t.sessionProcesses(tag: 'a', workingDir: dir, ownsDir: true, cwds: cwds), [21, 41]);
    // A sibling directory with the same prefix is not inside.
    expect(t.sessionProcesses(tag: 'a', workingDir: '/w/session', ownsDir: true, cwds: cwds), isEmpty);
  });

  test("the user's own tmux is never taken for the agent's", () {
    final t = ProcessTable([
      _row(11, 1, '/x/agent-server'),
      // The agent's tmux server detached from the agent-server but kept its environment.
      ProcessRow(pid: 60, ppid: 1, command: 'tmux -L oh new-session', serverEnv: true),
      _row(61, 60, '/bin/bash', env: false),
      _row(62, 61, '/bin/sleep 600', env: false),
      // The user's tmux, with a pane in the same folder running an editor and a dev server.
      _row(70, 1, 'tmux'),
      _row(71, 70, '/bin/zsh', env: false),
      _row(72, 71, 'nvim .'),
      _row(73, 71, 'npm run dev'),
    ]);
    final cwds = {61: dir, 71: dir};
    expect(t.sessionProcesses(tag: 'a', workingDir: dir, ownsDir: true, cwds: cwds), [62]);
    expect(t.sessionProcesses(tag: 'a', workingDir: dir, ownsDir: false, cwds: cwds), isEmpty);
  });

  test('parses ps output with and without the environment', () {
    const plain = '''
  101     1 /bin/sleep 600
  102     1 python gen.py --n 5
  103   102 node a.js
''';
    const withEnv = '''
  101     1 /bin/sleep 600
  102     1 python gen.py --n 5 HOME=/u EVERYAI_SESSION=abc-1 PATH=/bin
  103   102 node a.js HOME=/u
''';
    final t = ProcessTable.parsePs(withEnv, plain);
    expect(t.rows[101]!.envVisible, isFalse);
    expect(t.rows[102]!.tag, 'abc-1');
    expect(t.rows[102]!.command, 'python gen.py --n 5');
    expect(t.rows[103]!.tag, isNull);
    expect(t.rows[103]!.envVisible, isTrue);
    expect(t.rows[103]!.ppid, 102);
  });

  test('reads the tag from /proc environ', () {
    expect(ProcessTable.tagInEnviron('A=1\x00EVERYAI_SESSION=xyz\x00B=2'), 'xyz');
    expect(ProcessTable.tagInEnviron('A=1\x00B=2'), isNull);
  });

  test("the session's terminal is tagged with the session id", () async {
    Map<String, Object?>? sent;
    final harness = OpenHandsHarness(
      baseUrl: Uri.parse('http://127.0.0.1:1/'),
      sessionApiKey: 'k',
      client: MockClient((req) async {
        sent = jsonDecode(req.body) as Map<String, Object?>;
        return http.Response('{}', 200);
      }),
    );
    const spec = SessionSpec(
      workingDir: '/w',
      model: 'm',
      mode: AgentMode.ask,
      llmBaseUrl: 'http://x/v1',
      llmApiKey: 'k',
      sessionTag: 'sess-1',
    );
    await expectLater(harness.start(spec), throwsA(isA<HarnessError>()));
    final tools = ((sent!['agent']! as Map)['tools']! as List).cast<Map<String, Object?>>();
    final terminal = tools.firstWhere((t) => t['name'] == 'terminal');
    expect(terminal['params'], {
      'env': {sessionEnvVar: 'sess-1'},
    });
  });
}
