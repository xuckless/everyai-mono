// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:every_ai/core/process/supervisor.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/drivers/claude/claude_driver.dart';
import 'package:every_ai/features/code/drivers/codex/codex_driver.dart';
import 'package:every_ai/features/code/drivers/driver.dart' show ClosesVerified;
import 'package:every_ai/features/code/drivers/driver_link.dart';
import 'package:every_ai/features/code/drivers/driver_process.dart';
import 'package:every_ai/features/code/drivers/opencode/opencode_driver.dart';
import 'package:every_ai/features/code/drivers/opencode/opencode_server.dart';
import 'package:every_ai/features/code/drivers/short_run.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// Every process these tests start carries [marker] as its shell's $0, so the tearDown can tell whether any was left.
final marker = 'everyai-race-test-$pid';

List<String> leftovers() => [
  for (final l in const LineSplitter().convert(
    '${Process.runSync('ps', ['-A', '-ww', '-o', 'pid=,stat=,command='], environment: const {'LC_ALL': 'C'}).stdout}',
  ))
    if (l.contains(marker) && !l.contains(' ps ') && !RegExp(r'^\s*\d+\s+Z').hasMatch(l)) l.trim(),
];

void main() {
  late Directory tmp;
  late ProcessSupervisor sup;
  final original = ProcessSupervisor.instance;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('driver-races');
    sup = ProcessSupervisor.instance = ProcessSupervisor.create(ledgerDir: '${tmp.path}/ledger');
  });
  tearDown(() async {
    expect(
      [
        for (final c in sup.children)
          if (c.state.live) c.spec.label,
      ],
      isEmpty,
      reason: 'a child still listed',
    );
    await sup.stopAll();
    ProcessSupervisor.instance = original;
    expect(leftovers(), isEmpty, reason: 'a process still running');
    tmp.deleteSync(recursive: true);
  });

  /// A CLI that reads stdin forever (it never ends by itself).
  Future<DriverProcess> cli(String script, {String tag = 'race'}) => spawnDriver(
    executable: '/bin/sh',
    args: ['-c', script, marker],
    cwd: tmp.path,
    sessionTag: tag,
    logPath: '${tmp.path}/logs/$tag.log',
    closeInputFirst: false,
  );

  group('link', () {
    test('a close while the process starts stops it when it lands; nothing runs, nothing starts after', () async {
      final gate = Completer<void>();
      final link = DriverLink<DriverProcess>('race', (c) => c.close());
      final started = link.ensure(() async {
        await gate.future;
        return cli('sleep 30 & cat; wait');
      });
      final closed = link.close();
      expect(link.state, isA<LinkClosed<DriverProcess>>());
      gate.complete();
      await expectLater(started, throwsA(isA<HarnessError>()));
      expect(await closed, isA<Ended>());
      await expectLater(link.ensure(() => cli('cat')), throwsA(isA<HarnessError>()));
    });

    test('a drop while starting stops what lands; the next start is a new process', () async {
      final gate = Completer<void>();
      final link = DriverLink<DriverProcess>('race', (c) => c.close());
      final first = link.ensure(() async {
        await gate.future;
        return cli('cat');
      });
      final dropped = link.drop();
      gate.complete();
      await expectLater(first, throwsA(isA<HarnessError>()));
      expect(await dropped, isA<Ended>());
      final second = await link.ensure(() => cli('cat'));
      expect(link.live, same(second));
      expect(await link.close(), isA<Ended>());
    });

    test('the end of output is not an exit: the old process is stopped (verified) before another starts', () async {
      final link = DriverLink<DriverProcess>('race', (c) => c.close());
      // Closes its stdout and goes on running.
      final first = await link.ensure(() => cli('exec 1>&-; sleep 30'));
      await first.lines.toList();
      var exited = false;
      unawaited(first.exitCode.then((_) => exited = true));
      unawaited(link.gone(first));
      expect(link.state, isA<LinkStopping<DriverProcess>>());
      final second = await link.ensure(() async {
        // The old one has been seen gone by now.
        expect(exited, isTrue);
        return cli('cat');
      });
      expect(second, isNot(same(first)));
      expect(await link.close(), isA<Ended>());
    });

    test('two callers while it starts share one start', () async {
      var starts = 0;
      final link = DriverLink<DriverProcess>('race', (c) => c.close());
      Future<DriverProcess> start() {
        starts++;
        return cli('cat');
      }

      final (a, b) = await (link.ensure(start), link.ensure(start)).wait;
      expect(a, same(b));
      expect(starts, 1);
      await link.close();
    });

    test('refused moves are recorded, not taken', () {
      assertOnRefusedLinkMove = false;
      addTearDown(() => assertOnRefusedLinkMove = true);
      refusedLinkMoves.clear();
      final s = applyLinkEvent<String>(const LinkIdle(), const LinkLanded(1, 'x'));
      expect(s, isA<LinkIdle<String>>());
      expect(applyLinkEvent<String>(const LinkLive(1, 'a'), const LinkSpawn(2)), isA<LinkLive<String>>());
      expect(refusedLinkMoves, hasLength(1));
    });
  });

  test('Claude: a session closed while its CLI starts leaves no process', () async {
    final gate = Completer<void>();
    final spawned = <DriverProcess>[];
    final driver = ClaudeDriver(
      dataDir: () async => tmp.path,
      spawn: (args, {required cwd, required env, required sessionTag, required logPath}) async {
        await gate.future;
        final p = await cli('cat', tag: sessionTag);
        spawned.add(p);
        return p;
      },
    );
    final s = await driver.start(
      SessionSpec(
        workingDir: tmp.path,
        model: 'sonnet',
        mode: AgentMode.ask,
        llmBaseUrl: '',
        llmApiKey: '',
        sessionTag: 't',
      ),
    );
    final sending = s.send('hello');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final closing = (s as ClosesVerified).closeVerified();
    gate.complete();
    await expectLater(sending, throwsA(isA<HarnessError>()));
    expect(await closing, isA<Ended>());
    expect(spawned, hasLength(1));
    expect(await spawned.single.exitCode, isNot(0));
  });

  test('Codex: two opens of one thread at once start one app server', () async {
    final data = '${tmp.path}/data';
    File('$data/drivers/codex/threads/th1.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({'cwd': tmp.path, 'sessionTag': 't1', 'mode': 'ask'}));
    var spawns = 0;
    final gate = Completer<void>();
    final driver = CodexDriver(
      which: (_) async => '/bin/echo',
      dataDir: () async => data,
      spawn: ({required args, required cwd, required env, required sessionTag}) async {
        spawns++;
        await gate.future;
        // An app server that exits at once: the open fails, the same way for both callers.
        return cli('exit 0', tag: sessionTag);
      },
    );
    final a = driver.attach('th1');
    final b = driver.attach('th1');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    gate.complete();
    final results = await Future.wait([
      a.then<Object>((s) => s, onError: (Object e) => e),
      b.then<Object>((s) => s, onError: (Object e) => e),
    ]);
    expect(spawns, 1);
    expect(results.first, isA<HarnessError>());
    expect(results.last, same(results.first));
  });

  test('OpenCode: two opens of one session at once start one server', () async {
    final data = '${tmp.path}/data';
    File('$data/driver-sessions/opencode/ses1.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({'workingDir': tmp.path, 'sessionTag': 't2', 'model': 'a/b'}));
    var launches = 0;
    final gate = Completer<void>();
    final driver = OpenCodeDriver(
      which: (_) async => '/bin/echo',
      dataDir: () async => data,
      run: (exe, args) async => (exitCode: 1, stdout: ''),
      launch: ({required executable, required cwd, required sessionTag, required logPath, env = const {}}) async {
        launches++;
        await gate.future;
        throw const HarnessError("OpenCode's server didn't start.");
      },
    );
    final a = driver.attach('ses1');
    final b = driver.attach('ses1');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    gate.complete();
    await expectLater(a, throwsA(isA<HarnessError>()));
    await expectLater(b, throwsA(isA<HarnessError>()));
    expect(launches, 1);
  });

  test('OpenCode server: close is the verified stop of its process, once', () async {
    final p = await cli('sleep 30 & cat; wait');
    final server = OpenCodeServer(
      base: Uri.parse('http://127.0.0.1:9'),
      password: 'x',
      client: MockClient((_) async => http.Response('', 500)),
      process: p,
    );
    final (first, second) = await (server.close(), server.close()).wait;
    expect(first, isA<Ended>());
    expect(second, same(first));
    expect(server.exited, isTrue);
  });

  group('short commands', () {
    test('a hung command is stopped at its time limit, with what it started, and says so', () async {
      final r = await runShort('/bin/sh', [
        '-c',
        'sleep 30 & sleep 30',
        marker,
      ], timeout: const Duration(milliseconds: 300));
      // What it ran is ended (the tearDown checks nothing with the marker runs); an unrelated orphan with a hidden
      // environment may be named as not proven, never as survived.
      expect(r, isA<TimedOut>().having((t) => t.kill, 'kill', isNot(isA<Survived>())));
      expect(runProblem('sleepy', r), contains('took too long and was stopped'));
    });

    test('a cancelled command is stopped and says so', () async {
      final cancel = Completer<void>();
      final run = runShort(
        '/bin/sh',
        ['-c', 'sleep 30', marker],
        timeout: const Duration(minutes: 1),
        cancel: cancel.future,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      cancel.complete();
      final r = await run;
      expect(r, isA<Cancelled>());
      expect(runProblem('sleepy', r), contains('was cancelled'));
    });

    test('a missing program is a failed start, as "not installed" was', () async {
      final r = await runShort('/nonexistent/everyai-cli', const [], timeout: const Duration(seconds: 5));
      expect(r, isA<StartFailed>());
    });

    test('one in flight per key', () async {
      final once = SingleFlight<String, int>();
      var runs = 0;
      Future<int> work() async {
        runs++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return runs;
      }

      final (a, b) = await (once.run('k', work), once.run('k', work)).wait;
      expect((a, b, runs), (1, 1, 1));
      expect(await once.run('k', work), 2);
      // A future that is already complete is not kept.
      expect(await once.run('done', () => Future.value(7)), 7);
      await Future<void>.delayed(Duration.zero);
      expect(once.isRunning('done'), isFalse);
    });
  });
}
