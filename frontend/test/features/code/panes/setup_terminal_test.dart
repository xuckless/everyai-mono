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
}
