@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:every_ai/features/code/harness/everyai/llm.dart';
import 'package:every_ai/features/code/harness/everyai/shell_io.dart';
import 'package:every_ai/features/code/harness/everyai/tools_io.dart';
import 'package:every_ai/features/code/panes/pty.dart';
import 'package:every_ai/features/code/shells/shell_log_io.dart';
import 'package:every_ai/features/code/shells/shell_registry.dart';
import 'package:every_ai/features/code/shells/terminal_text.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pipes standing in for a pseudo-terminal (flutter_pty's library isn't loaded under `flutter test`): stdin stays
/// open, so input reaches the program the way it would through a pty.
final class _PipePty implements ShellPty {
  _PipePty(this._p) {
    final c = StreamController<Uint8List>.broadcast();
    var open = 2;
    void done() {
      if (--open == 0) c.close();
    }

    _p.stdout.listen((b) => c.add(Uint8List.fromList(b)), onDone: done);
    _p.stderr.listen((b) => c.add(Uint8List.fromList(b)), onDone: done);
    output = c.stream;
  }
  final Process _p;
  @override
  late final Stream<Uint8List> output;
  @override
  int get pid => _p.pid;
  @override
  Future<int> get exitCode => _p.exitCode;
  @override
  // A terminal's line discipline turns Enter (CR) into a newline (ICRNL).
  void write(Uint8List data) => _p.stdin.add([for (final b in data) b == 0x0D ? 0x0A : b]);
  @override
  void resize(int rows, int columns) {}
  @override
  void kill() => _p.kill();
}

Future<ShellPty?> _start(String exe, List<String> args, String cwd, Map<String, String> env) async =>
    _PipePty(await Process.start(exe, args, workingDirectory: cwd, environment: env));

void main() {
  group('terminal text', () {
    test('codes go, CRLF becomes LF, redrawn lines keep their last state', () {
      expect(cleanTerminalText('\x1B[32mok\x1B[0m\r\nnext'), 'ok\nnext');
      expect(cleanTerminalText('10%\r50%\r100%\ndone'), '100%\ndone');
      expect(cleanTerminalText('\x1B]0;title\x07hello'), 'hello');
      expect(cleanTerminalText('abc\b\bX'), 'aX');
      expect(cleanTerminalText('long line\rshort'), 'shortline');
    });

    test('prompts', () {
      expect(looksLikePrompt('Ok to proceed? (y)'), isTrue);
      expect(looksLikePrompt('Need to install the following packages: Ok to proceed? (y) '), isTrue);
      expect(looksLikePrompt('Continue? [Y/n]'), isTrue);
      expect(looksLikePrompt('Project name:'), isTrue);
      expect(looksLikePrompt('? Which framework? › React'), isTrue);
      expect(looksLikePrompt('Password'), isTrue);
      expect(looksLikePrompt('Compiled successfully in 120ms'), isFalse);
      expect(looksLikePrompt('  VITE v5.0.0  ready in 300 ms'), isFalse);
    });

    test('keys and what the user typed', () {
      expect(keySequence('enter'), '\r');
      expect(keySequence('ctrl-c'), '\x03');
      expect(keySequence('Ctrl+D'), '\x04');
      expect(keySequence('up'), '\x1B[A');
      expect(keySequence('hyper-x'), isNull);
      expect(describeTyped('rs\r'), 'rs⏎');
      expect(describeTyped('\x03'), '^C');
      expect(describeTyped('\x1B[Aq'), '↑q');
    });
  });

  group('shell log', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('shell-log'));
    tearDown(() => tmp.delete(recursive: true));

    test('rolls into .1 past its cap and reads back both segments in order', () async {
      final log = ShellLog('${tmp.path}/a.log', cap: 10)
        ..addText('0123456789AB')
        ..addText('cd');
      log.close();
      expect(File('${tmp.path}/a.log.1').readAsStringSync(), '0123456789AB');
      expect(utf8.decode(await readShellLog('${tmp.path}/a.log')), '0123456789ABcd');
    });
  });

  group('session shell', () {
    late Directory tmp;
    late String work;
    late ShellRegistry registry;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('shells');
      work = (await Directory('${tmp.path}/work').create()).path;
      registry = ShellRegistry.forTest();
    });
    tearDown(() => tmp.delete(recursive: true));

    SessionShell shell({bool pty = true}) => SessionShell(
      root: work,
      sessionTag: 's1',
      scratchDir: '${tmp.path}/sh',
      logDir: '${tmp.path}/logs',
      registry: registry,
      ptySpawner: pty ? _syncStart : null,
    );

    test('a background shell is registered, logged, and takes input', () async {
      final sh = shell();
      final bg = await sh.start('printf "Name? "; read n; echo "hi \$n"', description: 'greet');
      expect(bg.interactive, isTrue);
      final entry = registry.of('s1').single;
      expect(entry.id, 'bg_1');
      expect(entry.title, 'greet');
      expect(entry.background, isTrue);
      await _until(() => bg.output.contains('Name?'));
      expect(bg.waitingFor(quiet: Duration.zero), 'Name?');
      entry.live!.write(Uint8List.fromList(utf8.encode('bob\n')));
      await _until(() => !bg.running);
      expect(bg.takeNew(), contains('hi bob'));
      expect(entry.takeTyped(), 'bob⏎');
      expect(entry.running, isFalse);
      expect(entry.exitCode, 0);
      final log = utf8.decode(await readShellLog(entry.logPath!));
      expect(log, contains(r'$ printf'));
      expect(log, contains('hi bob'));
    });

    test('without a pty a background shell still runs, with stdin closed', () async {
      final bg = await shell(pty: false).start('read n || echo "no stdin"');
      expect(bg.interactive, isFalse);
      await _until(() => !bg.running);
      expect(bg.takeNew(), contains('no stdin'));
      expect(bg.write('x'), isFalse);
    });

    test('foreground commands are registered and logged with CRLF line ends', () async {
      final r = await shell().run('echo one; echo two', timeout: const Duration(seconds: 10));
      expect(r.output, 'one\ntwo\n');
      final entry = registry.of('s1').single;
      expect(entry.background, isFalse);
      expect(entry.exitCode, 0);
      expect(utf8.decode(await readShellLog(entry.logPath!)), endsWith('one\r\ntwo\r\n'));
    });

    test('bash_input types into the shell; bash_output tells what the user typed', () async {
      final sh = shell();
      final runner = ToolRunner(
        root: work,
        shell: sh,
        gateway: GatewayClient(baseUrl: 'http://127.0.0.1:9/v1', apiKey: ''),
        sessionTag: 's1',
      );
      final started = await runner.run('bash', {
        'command': 'while read l; do echo "got \$l"; done',
        'run_in_background': true,
      });
      expect(started.text, contains('bg_1'));
      final sent = await runner.run('bash_input', {
        'shell_id': 'bg_1',
        'text': 'hello',
        'keys': ['enter'],
      });
      expect(sent.text, contains('got hello'));
      final bad = await runner.run('bash_input', {
        'shell_id': 'bg_1',
        'keys': ['hyper-x'],
      });
      expect(bad.isError, isTrue);
      registry.of('s1').single.live!.write(Uint8List.fromList(utf8.encode('rs\n')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final out = await runner.run('bash_output', {'shell_id': 'bg_1'});
      expect(out.text, contains('got rs'));
      expect(out.text, contains('The user typed into this shell from the app: rs⏎'));
      await runner.run('kill_shell', {'shell_id': 'bg_1'});
    });

    test('the pty environment has colour and no pagers or git prompts', () {
      final env = ptyShellEnv({'NO_COLOR': '1', 'TERM': 'dumb', 'PATH': '/bin'}, 'tag');
      expect(env.containsKey('NO_COLOR'), isFalse);
      expect(env['TERM'], 'xterm-256color');
      expect(env['GIT_TERMINAL_PROMPT'], '0');
      expect(env['PAGER'], 'cat');
      expect(env['PATH'], '/bin');
    });
  });
}

Future<ShellPty?> _syncStart(String exe, List<String> args, String cwd, Map<String, String> env, int rows, int cols) =>
    _start(exe, args, cwd, env);

Future<void> _until(bool Function() ok, {Duration limit = const Duration(seconds: 10)}) async {
  final end = DateTime.now().add(limit);
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}
