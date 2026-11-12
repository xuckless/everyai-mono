import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../../core/preferences.dart';
import '../../../core/process/supervisor.dart'
    show
        ChildExited,
        ChildKilling,
        ChildLaunched,
        ChildNotClosed,
        ChildRunning,
        ChildStartFailed,
        ChildStarting,
        ChildState,
        ChildTerming,
        ChildUnverified,
        Ended;
import '../code_providers.dart';
import '../domain/local_ports.dart';
import 'processes.dart';
import 'pty.dart';

/// The tabs of a Code session's bottom drawer: the terminal only (Preview and Processes are tabs of the session
/// panel, `ConsoleView`).
enum CodePane {
  terminal('Terminal');

  const CodePane(this.label);
  final String label;
}

/// A session's console layout, Preferences `code.layout.<id>`: `{"panel", "panel_width", "drawer",
/// "drawer_height"}`. The right panel (`ConsolePanels`) and the drawer each write their own keys and keep the other's.
Map<String, Object?> readCodeLayout(Preferences prefs, String sessionId) {
  final raw = prefs['$codeLayoutPrefix$sessionId'];
  if (raw == null) return const {};
  try {
    return (jsonDecode(raw) as Map).cast<String, Object?>();
  } on Object {
    return const {};
  }
}

void writeCodeLayout(Preferences prefs, String sessionId, Map<String, Object?> changes) =>
    prefs['$codeLayoutPrefix$sessionId'] = jsonEncode({...readCodeLayout(prefs, sessionId), ...changes});

/// The drawer under a session's transcript: the tab open (null: closed), the last one open, and its height (null:
/// the default).
@immutable
final class PaneState {
  const PaneState({this.open, this.last = CodePane.terminal, this.height});
  final CodePane? open;
  final CodePane last;
  final double? height;
}

final codePaneProvider = NotifierProvider.family<CodePanes, PaneState, String>(CodePanes.new);

/// A session's bottom drawer, remembered in `code.layout.<id>` (`drawer`, `drawer_height`); it starts closed.
final class CodePanes extends Notifier<PaneState> {
  CodePanes(this.sessionId);
  final String sessionId;

  @override
  PaneState build() {
    final j = readCodeLayout(ref.read(preferencesProvider), sessionId);
    final open = CodePane.values.asNameMap()[j['drawer']];
    final last = CodePane.values.asNameMap()[j['drawer_last']] ?? open ?? CodePane.terminal;
    return PaneState(open: open, last: last, height: (j['drawer_height'] as num?)?.toDouble());
  }

  void _save() => writeCodeLayout(ref.read(preferencesProvider), sessionId, {
    'drawer': state.open?.name,
    'drawer_last': state.last.name,
    'drawer_height': state.height?.round(),
  });

  void show(CodePane pane) {
    state = PaneState(open: pane, last: pane, height: state.height);
    _save();
  }

  /// Opens [pane], or closes the drawer when it is the tab open.
  void toggle(CodePane pane) => state.open == pane ? close() : show(pane);

  /// Opens the last tab, or closes the drawer (⌃` and the header button).
  void toggleDrawer() => state.open != null ? close() : show(state.last);

  void close() {
    state = PaneState(last: state.last, height: state.height);
    _save();
  }

  /// A new height; [persist] is false while dragging, true at the end.
  void setHeight(double height, {bool persist = true}) {
    state = PaneState(open: state.open, last: state.last, height: height);
    if (persist) _save();
  }
}

/// Where a terminal tab's shell is (from its supervisor child's state):
///
/// ```text
///   idle ──start──▶ running ──TERM/KILL──▶ stopping ──exit──▶ exited(code)
///                     │                       └──survivors──▶ notClosed(pids) ──exit──▶ exited
///                     └──exit──────────────────────────────────────────────────────────▲
/// ```
@immutable
sealed class TerminalPhase {
  const TerminalPhase();
}

/// No shell started yet (or none on this platform).
final class TerminalIdle extends TerminalPhase {
  const TerminalIdle();
}

final class TerminalRunning extends TerminalPhase {
  const TerminalRunning(this.pid);
  final int pid;
}

final class TerminalStopping extends TerminalPhase {
  const TerminalStopping(this.pid);
  final int pid;
}

final class TerminalExited extends TerminalPhase {
  const TerminalExited(this.code);

  /// Null when its end was seen by a check (the code is unknown).
  final int? code;
}

/// Still running after SIGKILL, or its end couldn't be checked: it is not closed, and says so.
final class TerminalNotClosed extends TerminalPhase {
  const TerminalNotClosed(this.pids, this.reason);
  final List<int> pids;
  final String reason;
}

/// The phase a supervisor child's state means for a terminal.
TerminalPhase terminalPhaseOf(ChildState s, int pid) => switch (s) {
  ChildStarting() || ChildLaunched() || ChildRunning() || ChildUnverified() => TerminalRunning(pid),
  ChildTerming() || ChildKilling() => TerminalStopping(pid),
  ChildExited(:final code) => TerminalExited(code),
  ChildNotClosed(:final survivors, :final reason) => TerminalNotClosed([for (final p in survivors) p.pid], reason),
  ChildStartFailed() => const TerminalExited(null),
};

/// The shell in the Terminal pane: where it is ([phase]), and the local URLs it printed (oldest first).
@immutable
final class TerminalStatus {
  const TerminalStatus({this.phase = const TerminalIdle(), this.urls = const []});
  final TerminalPhase phase;
  final List<String> urls;

  /// Its pid while its process may be there (running, stopping, not closed).
  int? get pid => switch (phase) {
    TerminalRunning(:final pid) || TerminalStopping(:final pid) => pid,
    TerminalNotClosed(:final pids) => pids.first,
    TerminalIdle() || TerminalExited() => null,
  };

  /// Its exit code once it exited (null while it runs, isn't closed, or the code is unknown).
  int? get exitCode => switch (phase) {
    TerminalExited(:final code) => code,
    _ => null,
  };

  bool get running => phase is TerminalRunning;

  TerminalStatus withPhase(TerminalPhase p) => TerminalStatus(phase: p, urls: urls);
  TerminalStatus withUrls(List<String> u) => TerminalStatus(phase: phase, urls: u);
}

final sessionTerminalProvider = NotifierProvider.family<SessionTerminal, TerminalStatus, String>(SessionTerminal.new);

/// A session's terminal: an xterm buffer fed by a shell in the session's
/// folder. It outlives the pane, so switching tabs keeps the shell and its
/// scrollback. Its shell is owned by the app (see [startShell]: quit and the sweep end it, an agent's Stop doesn't).
final class SessionTerminal extends Notifier<TerminalStatus> {
  SessionTerminal(this.sessionId);
  final String sessionId;

  final terminal = Terminal(maxLines: 10000);
  ShellPty? _pty;
  StreamSubscription<String>? _sub;
  StreamSubscription<ChildState>? _states;

  /// The recent output, scanned for URLs.
  String _tail = '';
  static const _tailMax = 16 * 1024;

  @override
  TerminalStatus build() {
    ref.onDispose(() {
      // A dispose can't wait: the stop goes on, and one that doesn't close is logged (and stays listed).
      if (_detach() case final pty?) unawaited(_end(pty));
    });
    return const TerminalStatus();
  }

  /// Starts the shell in [workingDir] unless one is there (running, stopping or not closed); [command] is typed
  /// into it once it starts.
  void start(String workingDir, {String? command}) {
    if (_pty != null && state.pid != null) return;
    final pty = startShell(
      workingDir: workingDir,
      rows: terminal.viewHeight,
      columns: terminal.viewWidth,
      // Every tab of a session carries the session's id (a tab's own id is `<session>#<n>`).
      env: {'EVERYAI_TERMINAL': sessionId.split('#').first},
    );
    if (pty == null) {
      terminal.write('No shell on this platform.\r\n');
      return;
    }
    _pty = pty;
    if (command != null) pty.write(const Utf8Encoder().convert('$command\r'));
    state = state.withPhase(terminalPhaseOf(pty.child.state, pty.pid));
    _sub = pty.output.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).listen(_output);
    _states = pty.child.states.listen((s) {
      if (!identical(_pty, pty) || !ref.mounted) return;
      final next = terminalPhaseOf(s, pty.pid);
      if (next case TerminalExited(:final code) when state.phase is! TerminalExited) {
        terminal.write('\r\n[Process exited${code == null ? '' : ' with code $code'}]\r\n');
      } else if (next case TerminalNotClosed(:final pids)) {
        terminal.write('\r\n[Not closed: pids ${pids.join(', ')} are still running]\r\n');
      }
      state = state.withPhase(next);
    });
    terminal.onOutput = (data) => _pty?.write(const Utf8Encoder().convert(data));
    terminal.onResize = (w, h, pw, ph) => _pty?.resize(h, w);
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
    if (!listEquals(merged, state.urls)) state = state.withUrls(merged);
  }

  /// Ends the shell (and the jobs it started, verified) and starts a fresh one. When the old one doesn't close, no
  /// new one starts (the tab says what is still running).
  Future<void> restart(String workingDir) async {
    final old = _pty;
    if (old != null) {
      final out = await old.kill();
      if (out is! Ended) {
        terminal.write('\r\n[Not restarted: the old shell is not closed ($out)]\r\n');
        return;
      }
    }
    if (!ref.mounted) return;
    if (identical(_pty, old)) _detach();
    terminal.write('\r\n');
    state = TerminalStatus(urls: state.urls);
    start(workingDir);
  }

  /// Lets the current shell go (its output and state no longer reach this tab); returns it.
  ShellPty? _detach() {
    _sub?.cancel();
    _sub = null;
    _states?.cancel();
    _states = null;
    final pty = _pty;
    _pty = null;
    return pty;
  }

  static Future<void> _end(ShellPty pty) async {
    final out = await pty.kill();
    if (out is! Ended) debugPrint('NOT CLOSED: terminal shell ${pty.pid}: $out');
  }
}

/// The terminal tabs of one owner (a Code session's id, or [homeTerminalOwner] for the terminal outside sessions):
/// their terminal ids, in order, and the one showing. The first tab's id is the owner's own, so the session's
/// Processes and Preview keep reading the shell they always did; the others are `<owner>#<n>`.
@immutable
final class TerminalTabsState {
  const TerminalTabsState(this.ids, this.active, {this.labels = const {}});
  final List<String> ids;
  final int active;

  /// Names of tabs opened for a command ("logs · web"); others show their number.
  final Map<String, String> labels;

  String get activeId => ids[active.clamp(0, ids.length - 1)];
}

/// The owner id of the terminal on Code home (no session), started in the home folder.
const homeTerminalOwner = 'home';

final terminalTabsProvider = NotifierProvider.family<TerminalTabs, TerminalTabsState, String>(TerminalTabs.new);

final class TerminalTabs extends Notifier<TerminalTabsState> {
  TerminalTabs(this.owner);
  final String owner;
  int _next = 2;
  final _commands = <String, String>{};

  @override
  TerminalTabsState build() => TerminalTabsState([owner], 0);

  /// Opens a new tab and shows it.
  void add() {
    final ids = [...state.ids, '$owner#${_next++}'];
    state = TerminalTabsState(ids, ids.length - 1, labels: state.labels);
  }

  /// Opens a new tab named [label] whose shell runs [command] first (a container's logs, a shell inside it).
  void addCommand(String label, String command) {
    final id = '$owner#${_next++}';
    _commands[id] = command;
    final ids = [...state.ids, id];
    state = TerminalTabsState(ids, ids.length - 1, labels: {...state.labels, id: label});
  }

  /// The command tab [id] runs when its shell starts (once).
  String? takeCommand(String id) => _commands.remove(id);

  void show(int index) =>
      state = TerminalTabsState(state.ids, index.clamp(0, state.ids.length - 1), labels: state.labels);

  /// Shows the tab following shell [key] (see `shellTabId`), opening it after the others when there is none.
  void openShell(String key) {
    final id = '$owner@shell:$key';
    final at = state.ids.indexOf(id);
    if (at >= 0) return show(at);
    final ids = [...state.ids, id];
    state = TerminalTabsState(ids, ids.length - 1, labels: state.labels);
  }

  /// Closes the tab at [index] and ends its shell; the last tab stays (restart it instead).
  void close(int index) {
    // A stale index (the tab closed meanwhile, e.g. during a restart) closes nothing.
    if (state.ids.length < 2 || index < 0 || index >= state.ids.length) return;
    final id = state.ids[index];
    final ids = [...state.ids]..removeAt(index);
    final active = state.active > index || state.active == ids.length ? state.active - 1 : state.active;
    state = TerminalTabsState(ids, active.clamp(0, ids.length - 1), labels: {...state.labels}..remove(id));
    // A shell's tab only follows it: closing the tab leaves the shell running.
    if (!id.contains('@shell:')) ref.invalidate(sessionTerminalProvider(id));
  }
}

/// The session's processes and their ports, polled every 2 s while watched
/// (5 s on Windows, where each scan starts PowerShell). A table that can't be read is an error
/// ([ProcessesUnreadableError]), never an empty list.
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
    final app = ref.exists(codeSessionProvider(id)) ? ref.read(codeSessionProvider(id).notifier).appRunPid : null;
    switch (await listSessionProcesses(
      tag: info.id,
      workingDir: info.workingDir,
      ownsDir: info.worktree != null,
      agentRoots: {?app},
      terminalShells: {?shell.pid},
    )) {
      case ProcessesListed(:final processes):
        yield processes;
      case ProcessesUnreadable(:final why):
        // An error, not an empty list: the pane says it couldn't read them (the last list stays as the value).
        yield* Stream<List<SessionProcess>>.error(ProcessesUnreadableError(why));
    }
    await Future<void>.delayed(Duration(seconds: defaultTargetPlatform == TargetPlatform.windows ? 5 : 2));
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
