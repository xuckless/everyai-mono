import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:every_ai/features/code/environments/exec_env.dart';
import 'package:every_ai/core/process/supervisor.dart' show Ended, SupervisedChild;
import 'package:every_ai/features/code/panes/pty.dart';
import 'package:every_ai/features/code/panes/setup_terminal.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Pty implements ShellPty {
  final _out = StreamController<Uint8List>();
  final writes = <String>[];
  var kills = 0;
  @override
  int get pid => 1;
  @override
  Stream<Uint8List> get output => _out.stream;
  @override
  Future<int> get exitCode => Completer<int>().future;
  @override
  void write(Uint8List data) => writes.add(utf8.decode(data));
  @override
  void resize(int rows, int columns) {}
  @override
  Future<KillOutcome> kill() async {
    kills++;
    return const Ended([]);
  }

  @override
  SupervisedChild get child => throw UnimplementedError('not supervised (a fake)');
  void emit(String s) => _out.add(Uint8List.fromList(utf8.encode(s)));
}

final class _WslEnv extends ExecEnv {
  const _WslEnv();
  @override
  String get id => 'wsl:Ubuntu';
  @override
  EnvKind get kind => EnvKind.wsl;
  @override
  String get label => 'Ubuntu (WSL)';
  @override
  WrappedCommand wrap(String executable, List<String> args, {String? cwd, Map<String, String> env = const {}}) =>
      (executable: 'wsl.exe', args: ['-d', 'Ubuntu', '--', executable, ...args], environment: const {});
  @override
  String? toEnvPath(String hostPath) => null;
  @override
  String? toHostPath(String envPath) => null;
}

void main() {
  test('the command is typed without Enter, output reaches the terminal, and the shell is killed on dispose', () async {
    final pty = _Pty();
    final t = SetupTerminal(
      env: HostEnv.instance,
      starter: (_, _, _, _) async => pty,
      home: '/home/a',
      settle: () async {},
    );
    await t.start(first: 'curl -fsSL https://x.test/i.sh | bash');
    expect(pty.writes, ['curl -fsSL https://x.test/i.sh | bash']);
    expect(pty.writes.single, isNot(contains('\n')));
    expect(pty.writes.single, isNot(contains('\r')));

    pty.emit('hello\r\n');
    await pumpEventQueue();
    expect(t.terminal.buffer.getText(), contains('hello'));

    t.type('claude auth login');
    expect(pty.writes.last, 'claude auth login');

    t.dispose();
    expect(pty.kills, 1);
    expect(t.running, isFalse);
  });

  test('the first line waits for the shell to settle', () async {
    final pty = _Pty();
    final settled = Completer<void>();
    final t = SetupTerminal(
      env: HostEnv.instance,
      starter: (_, _, _, _) async => pty,
      home: '/h',
      settle: () => settled.future,
    );
    final started = t.start(first: 'curl x | bash');
    await pumpEventQueue();
    expect(pty.writes, isEmpty);
    settled.complete();
    await started;
    expect(pty.writes, ['curl x | bash']);
    t.dispose();
  });

  test('closing while the shell is still starting kills it and types nothing', () async {
    final pty = _Pty();
    final starting = Completer<ShellPty?>();
    final t = SetupTerminal(
      env: HostEnv.instance,
      starter: (_, _, _, _) => starting.future,
      home: '/h',
      settle: () async {},
    );
    final started = t.start(first: 'x');
    t.dispose();
    starting.complete(pty);
    await started;
    expect(pty.kills, 1);
    expect(pty.writes, isEmpty);
    expect(t.running, isFalse);
  });

  test('closing while the line waits to be typed types nothing', () async {
    final pty = _Pty();
    final settled = Completer<void>();
    final t = SetupTerminal(
      env: HostEnv.instance,
      starter: (_, _, _, _) async => pty,
      home: '/h',
      settle: () => settled.future,
    );
    final started = t.start(first: 'x');
    await pumpEventQueue();
    t.dispose();
    settled.complete();
    await started;
    expect(pty.writes, isEmpty);
  });

  test('a shell that cannot start is said in the terminal, not thrown', () async {
    final t = SetupTerminal(
      env: HostEnv.instance,
      starter: (_, _, _, _) async => throw StateError('no wsl.exe'),
      home: '/h',
    );
    await t.start(first: 'x');
    expect(t.terminal.buffer.getText(), contains('no wsl.exe'));
    expect(t.running, isFalse);
  });

  test('keys typed in the terminal go straight to the shell', () async {
    final pty = _Pty();
    final t = SetupTerminal(env: HostEnv.instance, starter: (_, _, _, _) async => pty, home: '/h', settle: () async {});
    await t.start();
    t.terminal.textInput('secret');
    expect(pty.writes.join(), 'secret');
    t.dispose();
  });

  test('no shell: says so', () async {
    final t = SetupTerminal(env: HostEnv.instance, starter: (_, _, _, _) async => null, home: '/h');
    await t.start(first: 'x');
    expect(t.terminal.buffer.getText(), contains('No shell'));
  });

  test('another environment starts the shell env.wrap makes; the host starts its own', () async {
    final started = <(String, List<String>, String, String)>[];
    final pty = _Pty();
    await startSetupShell(
      const _WslEnv(),
      '/home/a',
      24,
      80,
      program:
          ({
            required executable,
            required args,
            required workingDir,
            required sessionTag,
            rows = 24,
            columns = 80,
          }) async {
            started.add((executable, args, workingDir, sessionTag));
            return pty;
          },
    );
    final (exe, args, dir, tag) = started.single;
    expect(exe, 'wsl.exe');
    expect(args, ['-d', 'Ubuntu', '--', 'bash', '-l']);
    expect((dir, tag), ('/home/a', 'setup'));

    var hostDir = '';
    await startSetupShell(
      HostEnv.instance,
      '/home/a',
      24,
      80,
      host: ({required workingDir, rows = 24, columns = 80}) {
        hostDir = workingDir;
        return pty;
      },
      program: ({
        required executable,
        required args,
        required workingDir,
        required sessionTag,
        rows = 24,
        columns = 80,
      }) async => fail('the host does not wrap'),
    );
    expect(hostDir, '/home/a');
  });
}
