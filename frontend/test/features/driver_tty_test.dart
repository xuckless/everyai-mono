@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:every_ai/core/process/supervisor.dart';
import 'package:every_ai/features/code/drivers/driver_process_io.dart';
import 'package:flutter_test/flutter_test.dart';

/// Plain pipes stand in for the pty (flutter_pty's library isn't loaded
/// under `flutter test`); what is tested is the JSON on the named pipes.
Future<TtyProgram> _piped(String executable, List<String> args, String cwd, Map<String, String> env) async {
  final p = await Process.start(
    executable,
    args,
    workingDirectory: cwd,
    environment: env,
    includeParentEnvironment: false,
  );
  return (pid: p.pid, exitCode: p.exitCode, output: p.stdout);
}

void main() {
  late Directory tmp;
  late ProcessSupervisor sup;
  final original = ProcessSupervisor.instance;

  /// Every signal the supervisor sent, by pid (negative: a group).
  late List<int> signalled;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('driver-tty');
    signalled = [];
    sup = ProcessSupervisor.instance = ProcessSupervisor.create(
      ledgerDir: '${tmp.path}/ledger',
      hooks: SupervisorHooks(
        signal: (p, s) {
          signalled.add(p);
          return Process.killPid(p, s);
        },
      ),
    );
  });
  tearDown(() async {
    // Nothing these tests started is left running.
    expect([
      for (final c in sup.children)
        if (c.state.live) c.spec.label,
    ], isEmpty);
    await sup.stopAll();
    ProcessSupervisor.instance = original;
    await tmp.delete(recursive: true);
  });

  test('JSON lines go over the named pipes both ways; closing removes them', () async {
    final agent = File('${tmp.path}/agent.sh')
      ..writeAsStringSync(r'''
echo "to the log" >&2
while IFS= read -r line; do printf '%s\n' "$line"; done
''');
    final p = await spawnDriverTty(
      executable: '/bin/sh',
      args: [agent.path],
      cwd: tmp.path,
      sessionTag: 'tty-test',
      logPath: '${tmp.path}/s/stderr.log',
      start: _piped,
    );
    final first = p.lines.first;
    p.send('{"jsonrpc":"2.0","id":1,"method":"initialize"}');
    expect(await first, '{"jsonrpc":"2.0","id":1,"method":"initialize"}');
    expect(p.lastError, contains('to the log'));
    await p.close();
    expect(File('${tmp.path}/s/acp.in').existsSync(), isFalse);
    expect(File('${tmp.path}/s/acp.out').existsSync(), isFalse);
  });

  test('a program that exits before opening the pipes still ends its lines', () async {
    final p = await spawnDriverTty(
      executable: '/nonexistent/grok',
      args: const [],
      cwd: tmp.path,
      sessionTag: 'tty-test-2',
      logPath: '${tmp.path}/s/stderr.log',
      start: (exe, args, cwd, env) => _piped('/bin/sh', ['-c', 'exit 3'], cwd, env),
    );
    expect(await p.lines.toList(), isEmpty);
    expect(await p.exitCode, 3);
    await p.close();
  });

  test("last words: this run's stderr only, terminal output kept apart, odd bytes tolerated", () async {
    final log = File('${tmp.path}/s/stderr.log')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('Error: Device not configured (os error 6)\n');
    final agent = File('${tmp.path}/agent.sh')..writeAsStringSync("printf 'not logged in \\377\\n' >&2\n");
    final p = await spawnDriverTty(
      executable: '/bin/sh',
      args: [agent.path],
      cwd: tmp.path,
      sessionTag: 'tty-test-3',
      logPath: log.path,
      // What it writes to the terminal.
      start: (exe, args, cwd, env) async {
        final t = await _piped(exe, args, cwd, env);
        return (pid: t.pid, exitCode: t.exitCode, output: Stream.value(utf8.encode('terminal noise\n')));
      },
    );
    expect(await p.lines.toList(), isEmpty);
    await p.exitCode;
    expect(p.lastError, 'not logged in �\n');
    await p.close();
    expect(utf8.decode(log.readAsBytesSync(), allowMalformed: true), contains('os error 6)\nnot logged in'));
    expect(File('${tmp.path}/s/tty.log').readAsStringSync(), 'terminal noise\n');
  });

  group('close after the CLI exited leaves its pid alone (it may be reused)', () {
    test('piped driver', () async {
      final p = await spawnDriver(
        executable: '/bin/sh',
        args: ['-c', 'exit 0'],
        cwd: tmp.path,
        sessionTag: 'exited-pipe',
        logPath: '${tmp.path}/s/driver.log',
      );
      await p.exitCode;
      expect(await p.close(), isA<Ended>());
      expect(signalled, isEmpty);
    });

    test('tty driver', () async {
      final p = await spawnDriverTty(
        executable: '/bin/sh',
        args: const [],
        cwd: tmp.path,
        sessionTag: 'exited-tty',
        logPath: '${tmp.path}/s/stderr.log',
        start: (exe, args, cwd, env) => _piped('/bin/sh', ['-c', 'exit 0'], cwd, env),
      );
      await p.exitCode;
      expect(await p.close(), isA<Ended>());
      expect(signalled, isEmpty);
    });

    test('a running driver is ended, verified, with what it started', () async {
      final p = await spawnDriver(
        executable: '/bin/sh',
        args: ['-c', 'sleep 30 & read x; wait'],
        cwd: tmp.path,
        sessionTag: 'running-pipe',
        logPath: '${tmp.path}/s/driver.log',
        // Input closing would end it by itself: the stop must end it (and its sleep) by signal.
        closeInputFirst: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(await p.close(), isA<Ended>());
      expect(signalled, isNotEmpty);
      await p.exitCode;
    });

    test('a running tty driver is stopped through the supervisor, then its pipes go', () async {
      final p = await spawnDriverTty(
        executable: '/bin/sh',
        args: ['-c', 'sleep 30'],
        cwd: tmp.path,
        sessionTag: 'running-tty',
        logPath: '${tmp.path}/s/stderr.log',
        start: _piped,
      );
      expect(sup.children.where((c) => c.pid == p.pid), hasLength(1));
      expect(await p.close(), isA<Ended>());
      expect(File('${tmp.path}/s/acp.in').existsSync(), isFalse);
    });
  });

  test('the version check stops a CLI that hangs and says so', () async {
    final cli = File('${tmp.path}/hangs')
      ..writeAsStringSync('#!/bin/sh\nsleep 30\n')
      ..createSync();
    await Process.run('chmod', ['+x', cli.path]);
    final status = await detectCli('hangs', which: (_) async => cli.path);
    expect(status.installed, isTrue);
    expect(status.problem, contains("didn't say its version"));
  }, timeout: const Timeout(Duration(seconds: 20)));
}
