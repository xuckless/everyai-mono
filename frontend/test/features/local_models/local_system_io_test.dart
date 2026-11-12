@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:every_ai/core/process/supervisor.dart';
import 'package:every_ai/features/local_models/data/local_system.dart';
import 'package:every_ai/features/local_models/data/local_system_io.dart';
import 'package:every_ai/features/local_models/domain/local_server.dart';
import 'package:flutter_test/flutter_test.dart';

final nap = '31.$pid';

const fast = StopTimings(
  termGrace: Duration(milliseconds: 300),
  killWait: Duration(seconds: 2),
  poll: Duration(milliseconds: 25),
);

/// `sleep <nap>` processes of this test still running.
List<String> leftovers() => [
  for (final l in const LineSplitter().convert('${Process.runSync('ps', ['-A', '-o', 'pid=,stat=,command=']).stdout}'))
    if (l.contains('sleep $nap') && !l.contains(' Z')) l.trim(),
];

LocalServer server(LocalServerKind kind, {String url = 'http://127.0.0.1:11434/v1', String? start}) =>
    LocalServer(id: kind.name, kind: kind, label: kind.label, baseUrl: url, startCommand: start);

/// Every supervisor a test makes, closed before its folder goes (their ledger writes are batched).
final _made = _Made();

final class _Made {
  final _all = <ProcessSupervisor>[];
  ProcessSupervisor add(ProcessSupervisor s) {
    _all.add(s);
    return s;
  }

  Future<void> closeAll() async {
    await Future.wait([for (final s in _all) s.stopAll(timings: fast)]);
    _all.clear();
  }
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('local_system_io'));
  tearDown(() async {
    await _made.closeAll();
    expect(leftovers(), isEmpty);
    dir.deleteSync(recursive: true);
  });

  test('a server not on loopback is never stopped', () async {
    final system = IoLocalSystem(run: (_, _) async => fail('nothing may run'));
    final r = await system.stopListener(server(LocalServerKind.ollama, url: 'http://10.0.0.5:11434/v1'), port: 11434);
    expect(r, isA<ServerStopRefused>());
  });

  test("a listener that isn't the server's kind is left alone, and says who holds the port", () async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    final other = await Process.start('python3', ['-m', 'http.server', '$port', '--bind', '127.0.0.1']);
    addTearDown(() => other.kill(ProcessSignal.sigkill));
    final system = IoLocalSystem(supervisor: _made.add(ProcessSupervisor.create(ledgerDir: '${dir.path}/l')));
    // Up once it accepts a connection (lsof may be missing on Linux, where ss stands in for it).
    for (var i = 0; i < 100; i++) {
      try {
        await (await Socket.connect(InternetAddress.loopbackIPv4, port)).close();
        break;
      } on SocketException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    final r = await system.stopListener(server(LocalServerKind.ollama), port: port);
    expect(r, isA<ServerStopRefused>().having((r) => r.owner, 'owner', contains('http.server')));
    expect(await Future.any([other.exitCode, Future<int?>.delayed(const Duration(milliseconds: 300))]), isNull);
  }, skip: Process.runSync('which', ['python3']).exitCode != 0);

  test('listeners match on the program name only', () {
    final ollama = server(LocalServerKind.ollama);
    expect(listenerMatches(ollama, '/Applications/Ollama.app/Contents/Resources/ollama serve'), isTrue);
    expect(listenerMatches(ollama, 'ssh -N -L 11434:localhost:11434 ollama-box'), isFalse);
    expect(listenerMatches(server(LocalServerKind.jan), '/Users/janet/bin/llama-server --port 1337'), isFalse);
    expect(
      listenerMatches(server(LocalServerKind.lmstudio), '/Applications/LM Studio.app/Contents/MacOS/LM Studio --x'),
      isTrue,
    );
    expect(listenerMatches(server(LocalServerKind.vllm), 'python3 -m vllm.entrypoints.openai.api_server'), isTrue);
  });

  test(
    "a supervised non-server ancestor (a terminal tab, an agent's shell) is never stopped for its listener",
    () async {
      final sup = _made.add(
        ProcessSupervisor.create(
          ledgerDir: '${dir.path}/l',
          hooks: const SupervisorHooks(timings: fast),
        ),
      );
      final tab = await sup.spawn(
        SpawnSpec(
          owner: const AppOwner(),
          kind: ProcessKind.shell,
          exe: '/bin/sh',
          args: ['-c', 'sleep $nap & while :; do sleep 0.2; done'],
          label: 'terminal tab',
        ),
      );
      int? listener;
      for (var i = 0; i < 100 && listener == null; i++) {
        final r = Process.runSync('pgrep', ['-P', '${tab.pid}', '-f', 'sleep $nap']);
        listener = int.tryParse('${r.stdout}'.trim().split('\n').first);
        if (listener == null) await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(listener, isNotNull);
      final system = IoLocalSystem(
        supervisor: sup,
        run: (exe, args) async => exe.endsWith('lsof') ? (code: 0, out: '$listener\n') : null,
      );
      // A manual server whose program is `sleep`: only the listener ends, never the tab it runs in.
      final r = await system.stopListener(server(LocalServerKind.custom, start: 'sleep 1'), port: 11434);
      expect(r, isA<ServerStopEnded>());
      expect(Process.runSync('kill', ['-0', '$listener']).exitCode, isNot(0));
      expect(sup.byPid(tab.pid!)?.state.live, isTrue);
    },
  );

  test('a listener whose start time changed (its pid reused) is never signalled', () async {
    final signals = <int>[];
    var scans = 0;
    final sup = _made.add(
      ProcessSupervisor.create(
        ledgerDir: '${dir.path}/l',
        hooks: SupervisorHooks(
          timings: fast,
          scan: ({required env}) async {
            scans++;
            return Listed(
              ProcessList([
                ScanRow(pid: pid, ppid: 1, pgid: pid, start: 'me', command: 'test', uid: 501),
                // The second look finds pid 4242 started at another time: another program now.
                ScanRow(
                  pid: 4242,
                  ppid: 1,
                  pgid: 4242,
                  start: scans <= 1 ? 'A' : 'B',
                  command: '/usr/bin/ollama serve',
                  uid: 501,
                ),
              ]),
              at: DateTime.now(),
            );
          },
          signal: (p, s) {
            signals.add(p);
            return true;
          },
        ),
      ),
    );
    final system = IoLocalSystem(
      supervisor: sup,
      run: (exe, args) async => exe.endsWith('lsof') ? (code: 0, out: '4242\n') : null,
    );
    final r = await system.stopListener(server(LocalServerKind.ollama), port: 11434);
    expect(r, isA<ServerStopEnded>());
    expect(signals, isEmpty);
  });

  test('a server EveryAI started is still its own after a relaunch of the run (the ledger)', () async {
    final ledger = '${dir.path}/ledger';
    final first = _made.add(
      ProcessSupervisor.create(
        ledgerDir: ledger,
        hooks: const SupervisorHooks(timings: fast),
      ),
    );
    final launched = await IoLocalSystem(supervisor: first).launch('fm', 'sleep', [nap], port: 4567);
    expect(launched, isNotNull);
    await first.byPid(launched!.pid)!.landed;
    // A new supervisor on the same ledger (this process's run, as after a hot restart) takes it back.
    final again = _made.add(
      ProcessSupervisor.create(
        ledgerDir: ledger,
        hooks: const SupervisorHooks(timings: fast),
      ),
    );
    await again.ledgerDirectory;
    final system = IoLocalSystem(supervisor: again);
    expect(system.owns('fm'), isTrue);
    expect(system.ownedPort('fm'), 4567);
    expect(await system.stopOwned('fm'), isA<ServerStopEnded>());
    expect(system.owns('fm'), isFalse);
    await launched.exited;
  });

  test('a start command that puts the server in the background is still ended with its group', () async {
    final sup = _made.add(
      ProcessSupervisor.create(
        ledgerDir: '${dir.path}/l',
        hooks: const SupervisorHooks(timings: fast),
      ),
    );
    final system = IoLocalSystem(supervisor: sup);
    final launched = await system.launch('custom:1', 'sleep $nap & wait', const [], shell: true, port: 9000);
    expect(launched, isNotNull);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(leftovers(), isNotEmpty);
    expect(system.owns('custom:1'), isTrue);
    expect(await system.stopOwned('custom:1', grace: const Duration(milliseconds: 300)), isA<ServerStopEnded>());
  });

  test('a short command that hangs is killed at its timeout, and says so', () async {
    final sup = _made.add(
      ProcessSupervisor.create(
        ledgerDir: '${dir.path}/l',
        hooks: const SupervisorHooks(timings: fast),
      ),
    );
    final r = await runProgram(
      '/bin/sh',
      ['-c', 'sleep $nap'],
      timeout: const Duration(milliseconds: 300),
      supervisor: sup,
    );
    expect(r, isNotNull);
    expect(r!.code, -1);
    expect(r.out, 'timed out after 300 ms (killed)');
  });
}
