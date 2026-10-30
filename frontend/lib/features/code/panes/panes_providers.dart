import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../code_providers.dart';
import '../domain/local_ports.dart';
import 'processes.dart';
import 'pty.dart';

/// The tabs beside a Code session.
enum CodePane {
  diff('Changes'),
  terminal('Terminal'),
  processes('Processes'),
  preview('Preview');

  const CodePane(this.label);
  final String label;
}

/// Which pane is open beside a session (null: none), and the last one open.
@immutable
final class PaneState {
  const PaneState({this.open, this.last = CodePane.terminal});
  final CodePane? open;
  final CodePane last;
}

final codePaneProvider = NotifierProvider.family<CodePanes, PaneState, String>(CodePanes.new);

final class CodePanes extends Notifier<PaneState> {
  CodePanes(this.sessionId);
  final String sessionId;

  @override
  PaneState build() => const PaneState();

  void show(CodePane pane) => state = PaneState(open: pane, last: pane);

  /// Opens [pane], or closes it when it is the one open.
  void toggle(CodePane pane) => state.open == pane ? close() : show(pane);

  /// Opens the last pane, or closes the open one.
  void toggleLast() => state.open != null ? close() : show(state.last);

  void close() => state = PaneState(last: state.last);
}

/// The shell in the Terminal pane: its pid while running, how it ended, and
/// the local URLs it printed (oldest first).
@immutable
final class TerminalStatus {
  const TerminalStatus({this.pid, this.exitCode, this.urls = const []});
  final int? pid;
  final int? exitCode;
  final List<String> urls;

  bool get running => pid != null && exitCode == null;
}

final sessionTerminalProvider = NotifierProvider.family<SessionTerminal, TerminalStatus, String>(SessionTerminal.new);

/// A session's terminal: an xterm buffer fed by a shell in the session's
/// folder. It outlives the pane, so switching tabs keeps the shell and its
/// scrollback.
final class SessionTerminal extends Notifier<TerminalStatus> {
  SessionTerminal(this.sessionId);
  final String sessionId;

  final terminal = Terminal(maxLines: 10000);
  ShellPty? _pty;
  StreamSubscription<String>? _sub;

  /// The recent output, scanned for URLs.
  String _tail = '';
  static const _tailMax = 16 * 1024;

  @override
  TerminalStatus build() {
    ref.onDispose(_stop);
    return const TerminalStatus();
  }

  /// Starts the shell in [workingDir] unless it is running.
  void start(String workingDir) {
    if (_pty != null && state.running) return;
    final pty = startShell(
      workingDir: workingDir,
      rows: terminal.viewHeight,
      columns: terminal.viewWidth,
      env: {'EVERYAI_TERMINAL': sessionId},
    );
    if (pty == null) {
      terminal.write('No shell on this platform.\r\n');
      return;
    }
    _pty = pty;
    state = TerminalStatus(pid: pty.pid, urls: state.urls);
    _sub = pty.output.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).listen(_output);
    terminal.onOutput = (data) => _pty?.write(const Utf8Encoder().convert(data));
    terminal.onResize = (w, h, pw, ph) => _pty?.resize(h, w);
    pty.exitCode.then((code) {
      if (!identical(_pty, pty)) return;
      terminal.write('\r\n[Process exited with code $code]\r\n');
      if (ref.mounted) state = TerminalStatus(pid: state.pid, exitCode: code, urls: state.urls);
    });
  }

  void _output(String data) {
    terminal.write(data);
    _tail += data;
    if (_tail.length > _tailMax) _tail = _tail.substring(_tail.length - _tailMax);
    if (!data.contains('://') && !data.contains('localhost')) return;
    final urls = detectLocalUrls(_tail);
    // Keep URLs that scrolled out of the tail, newest last.
    final merged = [
      for (final u in state.urls)
        if (!urls.contains(u)) u,
      ...urls,
    ];
    if (!listEquals(merged, state.urls)) state = TerminalStatus(pid: state.pid, exitCode: state.exitCode, urls: merged);
  }

  /// Ends the shell (and the jobs it started) and starts a fresh one.
  void restart(String workingDir) {
    _stop();
    terminal.write('\r\n');
    state = TerminalStatus(urls: state.urls);
    start(workingDir);
  }

  void _stop() {
    _sub?.cancel();
    _sub = null;
    _pty?.kill();
    _pty = null;
  }
}

/// The session's processes and their ports, polled every 2 s while watched.
final sessionProcessesProvider = StreamProvider.autoDispose.family<List<SessionProcess>, String>((ref, id) async* {
  var alive = true;
  ref.onDispose(() => alive = false);
  while (alive) {
    final info = ref.read(codeSessionsProvider).where((s) => s.id == id).firstOrNull;
    if (info == null || isDemoPath(info.workingDir)) {
      yield const [];
      return;
    }
    final shell = ref.read(sessionTerminalProvider(id));
    yield await listSessionProcesses(
      tag: info.id,
      workingDir: info.workingDir,
      ownsDir: info.worktree != null,
      terminalShells: {if (shell.running) shell.pid!},
    );
    await Future<void>.delayed(const Duration(seconds: 2));
  }
});

/// The address in a session's Preview pane (null: nothing chosen yet).
final previewUrlProvider = NotifierProvider.family<PreviewUrl, String?, String>(PreviewUrl.new);

final class PreviewUrl extends Notifier<String?> {
  PreviewUrl(this.sessionId);
  final String sessionId;

  @override
  String? build() => null;

  void set(String? url) => state = url;
}
