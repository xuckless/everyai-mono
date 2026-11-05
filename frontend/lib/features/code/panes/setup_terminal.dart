// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../environments/exec_env.dart';
import 'pty.dart';

/// Starts a shell for the setup terminal in [env] with [home] as its folder; null where there is no pty.
typedef SetupShellStarter = Future<ShellPty?> Function(ExecEnv env, String home, int rows, int columns);

/// The real starter: the user's login shell here, or the shell [ExecEnv.wrap] makes for another environment.
/// [host] and [program] stand in for the pty starters in tests.
Future<ShellPty?> startSetupShell(
  ExecEnv env,
  String home,
  int rows,
  int columns, {
  ShellPty? Function({required String workingDir, int rows, int columns}) host = _startHostShell,
  Future<ShellPty?> Function({
        required String executable,
        required List<String> args,
        required String workingDir,
        required String sessionTag,
        int rows,
        int columns,
      })
      program =
      startProgram,
}) async {
  if (env.isHost) return host(workingDir: home, rows: rows, columns: columns);
  final shell = env.wrap('bash', const ['-l']);
  // The tag is not a session id, so Stop never touches this shell.
  return program(
    executable: shell.executable,
    args: shell.args,
    workingDir: home,
    sessionTag: 'setup',
    rows: rows,
    columns: columns,
  );
}

ShellPty? _startHostShell({required String workingDir, int rows = 24, int columns = 80}) =>
    startShell(workingDir: workingDir, rows: rows, columns: columns);

/// The starter the setup dialog uses; tests replace it.
final setupShellStarterProvider = Provider<SetupShellStarter>((ref) => startSetupShell);

/// A shell for setting a CLI up, outside any session: an xterm buffer fed by a login shell in [home]. The app only
/// types the lines it is given ([type]); it never presses Enter, and what the user types (passwords included) goes
/// from the terminal view straight to the shell.
final class SetupTerminal {
  SetupTerminal({required this.env, required this.starter, required this.home});

  final ExecEnv env;
  final SetupShellStarter starter;
  final String home;

  final terminal = Terminal(maxLines: 5000);
  ShellPty? _pty;
  StreamSubscription<String>? _sub;

  /// Whether a shell is running.
  bool get running => _pty != null;

  /// Starts the shell, then types [first] (no Enter) if given.
  Future<void> start({String? first}) async {
    if (_pty != null) return;
    final pty = await starter(env, home, terminal.viewHeight, terminal.viewWidth);
    if (pty == null) {
      terminal.write('No shell on this platform.\r\n');
      return;
    }
    _pty = pty;
    _sub = pty.output.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).listen(terminal.write);
    terminal.onOutput = (data) => _pty?.write(Uint8List.fromList(utf8.encode(data)));
    terminal.onResize = (w, h, pw, ph) => _pty?.resize(h, w);
    unawaited(
      pty.exitCode.then((code) {
        if (!identical(_pty, pty)) return;
        terminal.write('\r\n[Process exited with code $code]\r\n');
      }),
    );
    if (first != null) type(first);
  }

  /// Types [text] at the prompt without Enter.
  void type(String text) => _pty?.write(Uint8List.fromList(utf8.encode(text)));

  /// Ends the shell and what it started.
  void dispose() {
    _sub?.cancel();
    _sub = null;
    _pty?.kill();
    _pty = null;
  }
}
