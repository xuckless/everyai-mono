// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:every_ai/core/process/supervisor.dart';
import 'package:every_ai/features/code/harness/everyai/llm.dart';
import 'package:every_ai/features/code/harness/everyai/shell_io.dart';
import 'package:every_ai/features/code/harness/everyai/tools_io.dart';
import 'package:every_ai/features/code/shells/shell_registry.dart';
import 'package:flutter_test/flutter_test.dart';

// Every process these tests start sleeps [nap] seconds, so the tearDown can tell whether any was left behind.
final nap = '30.$pid';

const fast = StopTimings(
  termGrace: Duration(milliseconds: 400),
  killWait: Duration(seconds: 1),
  poll: Duration(milliseconds: 25),
);

List<int> naps() => [
  for (final l in const LineSplitter().convert(
    '${Process.runSync('ps', ['-A', '-ww', '-o', 'pid=,stat=,command='], environment: const {'LC_ALL': 'C'}).stdout}',
  ))
    if (l.contains('sleep $nap') && !l.contains(' Z')) int.parse(l.trim().split(RegExp(r'\s+')).first),
];

Future<void> eventually(bool Function() ok, {Duration within = const Duration(seconds: 8)}) async {
  final until = DateTime.now().add(within);
  while (!ok()) {
    if (DateTime.now().isAfter(until)) fail('timed out waiting');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  final made = <ProcessSupervisor>[];
  late Directory tmp;
  late Directory ledgers;
  late ShellRegistry registry;

  setUpAll(() {
    // The launcher the supervisor finds in frontend/.tools (as in development).
    if (!File('.tools/everyai-exec').existsSync()) {
      final r = Process.runSync('tool/build_exec_helper.sh', const []);
      expect(r.exitCode, 0, reason: '${r.stderr}');
    }
    ShellEnv.debugUse(ShellEnv.test('/bin/sh', {...Platform.environment, 'TERM': 'dumb'}));
    // Outside each test's folder: a supervisor still checking a not-closed child keeps writing its ledger.
    ledgers = Directory.systemTemp.createTempSync('shell-sup-ledgers');
  });
  tearDownAll(() {
    ShellEnv.debugUse(null);
    ledgers.deleteSync(recursive: true);
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('shell-sup');
    registry = ShellRegistry.forTest();
  });
  tearDown(() async {
    // Whatever a test left (an unkillable fake's real processes) is ended here, and then nothing may be left.
    for (final p in naps()) {
      Process.killPid(p, ProcessSignal.sigkill);
    }
    await eventually(() => naps().isEmpty);
    // Closed before the ledgers' folder goes (tearDownAll): their writes are batched.
    await Future.wait([for (final s in made) s.stopAll(timings: fast)]);
    made.clear();
    await tmp.delete(recursive: true);
  });

  ProcessSupervisor supervisor({SupervisorHooks hooks = const SupervisorHooks(timings: fast)}) {
    final s = ProcessSupervisor.create(hooks: hooks, ledgerDir: '${ledgers.path}/${tmp.path.split('/').last}');
    made.add(s);
    return s;
  }

  SessionShell shell(ProcessSupervisor sup) => SessionShell(
    root: tmp.path,
    sessionTag: 'sup-test',
    scratchDir: '${tmp.path}/sh',
    registry: registry,
    ptySpawner: null,
    supervisor: sup,
  );

  test('a TERM-ignoring command with a grandchild is ended on cancel; its entry reads exited', () async {
    final sh = shell(supervisor());
    final cancel = Future<void>.delayed(const Duration(milliseconds: 600));
    final r = await sh.run(
      'trap "" TERM; sleep $nap & sleep $nap',
      timeout: const Duration(seconds: 30),
      cancel: cancel,
    );
    expect(r.cancelled, isTrue);
    expect(r.stop, isA<Ended>());
    expect(r.closed, isTrue);
    final entry = registry.of('sup-test').single;
    expect(entry.state, isA<ShellExited>());
    expect(entry.running, isFalse);
    expect(naps(), isEmpty);
  });

  test('a command past its timeout is ended with its tree, verified', () async {
    final sh = shell(supervisor());
    final r = await sh.run('sleep $nap', timeout: const Duration(milliseconds: 500));
    expect(r.timedOut, isTrue);
    expect(r.stop, isA<Ended>());
    expect(registry.of('sup-test').single.state, isA<ShellExited>());
    expect(naps(), isEmpty);
  });

  test('a command that outlives its stop reads not closed, and the tool result says so', () async {
    // Signals "sent" but nothing happens: the command can't be ended.
    final sup = supervisor(
      hooks: SupervisorHooks(timings: fast, signal: (_, _) => true),
    );
    final sh = shell(sup);
    final runner = ToolRunner(
      root: tmp.path,
      shell: sh,
      gateway: GatewayClient(baseUrl: 'http://127.0.0.1:9/v1', apiKey: ''),
      sessionTag: 'sup-test',
    );
    final out = await runner.run('bash', {'command': 'sleep $nap', 'timeout': 1000});
    expect(out.isError, isTrue);
    expect(out.text, contains('not closed'));
    final entry = registry.of('sup-test').single;
    expect(entry.state, isA<ShellNotClosed>());
    expect(entry.running, isTrue);
    expect(entry.notClosed, isTrue);
    expect(naps(), isNotEmpty);
  });

  test('kill_shell says Stopped only when it is; Restart refuses while the old copy lives', () async {
    final sup = supervisor(
      hooks: SupervisorHooks(timings: fast, signal: (_, _) => true),
    );
    final sh = shell(sup);
    final runner = ToolRunner(
      root: tmp.path,
      shell: sh,
      gateway: GatewayClient(baseUrl: 'http://127.0.0.1:9/v1', apiKey: ''),
      sessionTag: 'sup-test',
    );
    final bg = await sh.start('sleep $nap');
    final restart = await sh.restart(bg.id);
    expect(restart, isA<RestartRefused>());
    expect(registry.of('sup-test').where((e) => e.id == bg.id), hasLength(1), reason: 'no second copy');
    expect(naps(), hasLength(1));
    final note = await runner.run('bash_output', {'shell_id': bg.id});
    expect(note.text, contains('did not close'));
    final killed = await runner.run('kill_shell', {'shell_id': bg.id});
    expect(killed.isError, isTrue);
    expect(killed.text, startsWith('Not closed'));
    expect(bg.state, isA<ShellNotClosed>());
  });

  test('a background shell that ended leaving a nohup child: killAll ends that too', () async {
    final sh = shell(supervisor());
    final bg = await sh.start('nohup sleep $nap >/dev/null 2>&1 &');
    await eventually(() => !bg.running);
    expect(naps(), hasLength(1), reason: 'the orphan runs on');
    final out = await sh.killAll();
    expect(out, isA<Ended>());
    await eventually(() => naps().isEmpty);
  });

  test('kill_shell on a running shell stops it and says so', () async {
    final sh = shell(supervisor());
    final runner = ToolRunner(
      root: tmp.path,
      shell: sh,
      gateway: GatewayClient(baseUrl: 'http://127.0.0.1:9/v1', apiKey: ''),
      sessionTag: 'sup-test',
    );
    final bg = await sh.start('sleep $nap');
    final out = await runner.run('kill_shell', {'shell_id': bg.id});
    expect(out.text, 'Stopped ${bg.id}.');
    await eventually(() => bg.state is ShellExited);
    expect(naps(), isEmpty);
  });
}
