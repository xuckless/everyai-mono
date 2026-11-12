import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'dart:io' show Directory, ProcessSignal, pid;

import 'package:every_ai/core/process/supervisor.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/drivers/driver_process.dart' show closeAllDriverProcesses;
import 'package:every_ai/features/code/drivers/terminal/terminal_driver.dart';
import 'package:every_ai/features/code/drivers/terminal/terminal_session.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/harness/session_processes.dart';
import 'package:every_ai/features/code/panes/pty.dart';
import 'package:flutter_test/flutter_test.dart';

/// Now, as `ps -o lstart=` says it (the adoption checks the pty's process started just now).
var _started = '';

String _lstartNow() {
  final t = DateTime.now();
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  String two(int n) => n.toString().padLeft(2, '0');
  return '${days[t.weekday - 1]}_${months[t.month - 1]}_${t.day}_${two(t.hour)}:${two(t.minute)}:${two(t.second)}_${t.year}';
}

/// What the fake supervisor's process table holds, and the signals it was asked to send.
final _alive = <int>{};
final _signals = <(int, ProcessSignal)>[];

/// A supervisor over a fake table: a signal ends the pid at once.
ProcessSupervisor _fakeSupervisor() => ProcessSupervisor.create(
  hooks: SupervisorHooks(
    scan: ({required bool env}) async => Listed(
      ProcessList([for (final p in _alive) ScanRow(pid: p, ppid: pid, pgid: pid, start: _started, command: 'aider')]),
      at: DateTime.now(),
    ),
    signal: (p, sig) {
      _signals.add((p, sig));
      _alive.remove(p.abs());
      return true;
    },
    timings: const StopTimings(
      termGrace: Duration(milliseconds: 100),
      killWait: Duration(milliseconds: 100),
      poll: Duration(milliseconds: 10),
    ),
  ),
  ledgerDir: Directory.systemTemp.createTempSync('terminal-driver-sup').path,
);

final class FakePty implements ShellPty {
  FakePty() {
    _started = _lstartNow();
    _alive.add(pid);
  }
  final _out = StreamController<Uint8List>();
  final _exit = Completer<int>();
  final writes = <List<int>>[];

  /// Its supervisor record, set when the (fake) pty layer adopts it.
  @override
  late final SupervisedChild child;

  /// Signals the supervisor sent to it (the session's close goes through the supervisor, never [kill]).
  int get kills => _signals.where((s) => s.$1.abs() == pid).length;

  @override
  int get pid => 4242;
  @override
  Stream<Uint8List> get output => _out.stream;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  void write(Uint8List data) => writes.add(data);
  @override
  void resize(int rows, int columns) {}
  @override
  Future<KillOutcome> kill() => fail('closed through the pty instead of its supervisor record');

  void emit(String s) => _out.add(Uint8List.fromList(utf8.encode(s)));
  void exit(int code) {
    _alive.remove(pid);
    _exit.complete(code);
  }

  List<String> get texts => [for (final w in writes) utf8.decode(w)];
}

SessionSpec _spec({DriverBriefing? briefing, String? initial}) => SessionSpec(
  initialMessage: initial,
  workingDir: '/work',
  model: 'm',
  mode: AgentMode.ask,
  llmBaseUrl: 'http://127.0.0.1:9/v1',
  llmApiKey: 'k',
  sessionTag: 'tag-t',
  briefing: briefing,
);

TerminalDriver _driver(
  FakePty? pty, {
  List<Map<String, Object?>>? started,
  Future<String?> Function(String)? read,
  Future<void> Function()? settle,
}) => TerminalDriver(
  id: 'terminal:aider',
  label: 'aider',
  command: 'aider',
  args: const ['--no-auto-commits'],
  which: (c) async => c == 'aider' ? '/bin/aider' : null,
  startPty: ({required executable, required args, required workingDir, required sessionTag, owner, sup, label}) async {
    started?.add({'exe': executable, 'args': args, 'cwd': workingDir, 'tag': sessionTag});
    // The pty layer adopts it once, for the session, with the driver's supervisor (as `startProgram` does).
    expect(owner, isA<SessionOwner>().having((o) => o.id, 'id', sessionTag));
    expect(sup, same(_sup));
    if (pty != null) {
      pty.child = sup!.adopt(
        pty.pid,
        SpawnSpec(owner: owner!, kind: ProcessKind.pty, exe: executable, args: args, label: label),
        exitCode: pty.exitCode,
        startedWithin: const Duration(seconds: 10),
      );
    }
    return pty;
  },
  supervisor: _sup,
  readText: read ?? (_) async => null,
  settle: settle ?? () async {},
);

Future<(TerminalSession, FakePty)> _open({DriverBriefing? briefing, Future<String?> Function(String)? read}) async {
  final pty = FakePty();
  final s = await _driver(pty, read: read).start(_spec(briefing: briefing)) as TerminalSession;
  pty.emit('> ');
  await Future<void>.delayed(Duration.zero);
  return (s, pty);
}

late ProcessSupervisor _sup;

void main() {
  setUp(() {
    _alive.clear();
    _signals.clear();
    _sup = _fakeSupervisor();
  });
  tearDown(() => _sup.stopAll());

  group('driver', () {
    test('start gives the pty its program, folder and tag, and registers the pid', () async {
      final started = <Map<String, Object?>>[];
      final pty = FakePty();
      final s = await _driver(pty, started: started).start(_spec());
      expect(started.single, {
        'exe': '/bin/aider',
        'args': ['--no-auto-commits'],
        'cwd': '/work',
        'tag': 'tag-t',
      });
      expect(driverRootsOf('tag-t'), {4242});
      await s.close();
      expect(driverRootsOf('tag-t'), isEmpty);
      expect(pty.kills, 1);
      await s.close();
      expect(pty.kills, 1);
    });
  });

  group('session', () {
    test('plain paste folds newlines, then Return', () async {
      final (s, pty) = await _open();
      await s.send('hi\nthere');
      expect(pty.texts, ['hi there', '\r']);
    });

    test('the first prompt is shown at once and pasted after the CLI draws', () async {
      final pty = FakePty();
      final s = await _driver(pty).start(_spec(initial: 'fix the test')) as TerminalSession;
      final seen = <HarnessEvent>[];
      s.events.listen(seen.add);
      await Future<void>.delayed(Duration.zero);
      expect(seen.whereType<ChatMessage>().where((m) => m.fromUser).map((m) => m.text), ['fix the test']);
      expect(pty.writes, isEmpty);
      pty.emit('aider> ');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(pty.texts, ['fix the test', '\r']);
    });

    test('after the CLI exits a send says so, writes nothing, and close does not kill', () async {
      final (s, pty) = await _open();
      pty.exit(0);
      await Future<void>.delayed(Duration.zero);
      expect(driverRootsOf('tag-t'), isEmpty);
      await s.send('more');
      expect(pty.writes, isEmpty);
      await s.close();
      expect(pty.kills, 0);
      final texts = (await s.events.toList()).whereType<ChatMessage>().where((m) => !m.fromUser).map((m) => m.text);
      expect(texts.last, contains('has ended'));
    });

    test('quitting the app closes terminal sessions', () async {
      final (_, pty) = await _open();
      await closeAllDriverProcesses();
      expect(pty.kills, 1);
    });

    test('exit 0 finishes; another code is an error', () async {
      final (s, pty) = await _open();
      final seen = <HarnessEvent>[];
      s.events.listen(seen.add);
      pty.exit(0);
      await Future<void>.delayed(Duration.zero);
      expect(seen.whereType<StateChange>().last.executionStatus, ExecutionStatus.finished);

      final (s2, pty2) = await _open();
      final seen2 = <HarnessEvent>[];
      s2.events.listen(seen2.add);
      pty2.exit(2);
      await Future<void>.delayed(Duration.zero);
      expect(seen2.whereType<ConversationFailure>().single.message, contains('code 2'));
      expect(seen2.whereType<StateChange>().last.executionStatus, ExecutionStatus.error);
    });
  });
}
