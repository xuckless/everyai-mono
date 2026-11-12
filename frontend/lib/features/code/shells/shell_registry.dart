// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show immutable, visibleForTesting;

import '../../../core/process/child_state.dart';
import '../../../core/process/process_model.dart' show Ended, KillOutcome, ScanFailed, Survived;
import 'terminal_text.dart';

/// Who started a shell.
enum ShellOrigin {
  /// The agent's bash tool (foreground or background).
  agent('agent'),

  /// app_run: the project's app.
  appRun('app'),

  /// A check or hook EveryAI ran.
  check('check'),

  /// An outside lead's own process we only watch (its output may be a file we tail).
  outside('outside');

  const ShellOrigin(this.label);
  final String label;
}

/// The live end of a running shell: its output as it comes, and, for one in a
/// pseudo-terminal, input and size.
abstract interface class LiveShell {
  /// Whether [write] reaches a terminal the program reads (false: pipes, or
  /// a process we only watch).
  bool get interactive;

  void write(Uint8List data);
  void resize(int rows, int columns);

  /// Ends it with a verified stop; the entry's [ShellEntry.state] says how that went (not closed stays listed).
  Future<void> stop();
}

/// Where a shell's process is, as its supervisor child says (see `ChildState`): the Processes tab, the terminal
/// tab that follows it and the agent's tools read this, never a guess.
///
/// ```text
///   running ──TERM/KILL──▶ stopping ──exit──▶ exited(code)
///      │                      │ survivors ──▶ notClosed(pids) ──exit──▶ exited
///      └──────────exit──────────────────────────────▲   exited ──its group left processes──▶ notClosed
/// ```
@immutable
sealed class ShellState {
  const ShellState();
}

final class ShellRunning extends ShellState {
  const ShellRunning(this.pid);
  final int? pid;
  @override
  String toString() => 'running($pid)';
}

/// A stop is under way (SIGTERM or SIGKILL sent).
final class ShellStopping extends ShellState {
  const ShellStopping(this.pid);
  final int? pid;
  @override
  String toString() => 'stopping($pid)';
}

final class ShellExited extends ShellState {
  const ShellExited(this.code, this.at);

  /// Its own exit code; null when its end was seen by a check (the code is unknown).
  final int? code;
  final DateTime at;
  @override
  String toString() => 'exited($code)';
}

/// Still running after SIGKILL (or not checkable): it stays listed, loudly.
final class ShellNotClosed extends ShellState {
  const ShellNotClosed(this.pids, this.reason);
  final List<int> pids;
  final String reason;
  @override
  String toString() => 'notClosed($pids: $reason)';
}

/// The shell state a supervisor child's [s] means.
ShellState shellStateOf(ChildState s) => switch (s) {
  ChildStarting() => const ShellRunning(null),
  ChildLaunched(:final pid) || ChildUnverified(:final pid) => ShellRunning(pid),
  ChildRunning(:final pid) => ShellRunning(pid),
  ChildTerming(:final id) || ChildKilling(:final id) => ShellStopping(id.pid),
  ChildExited(:final code, :final at) => ShellExited(code, at),
  ChildNotClosed(:final survivors, :final reason) => ShellNotClosed([for (final p in survivors) p.pid], reason),
  ChildStartFailed() => ShellExited(null, DateTime.now()),
  // Its pid turned out not to be the process started (gone or reused): never signalled, so not known closed.
  ChildDisowned(:final pid, :final why) => ShellNotClosed([pid], 'not ours any more: $why'),
};

/// [o] in words, for tool results and notes: what is still running and why.
String killOutcomeText(KillOutcome o) => switch (o) {
  Ended(maybeEscaped: []) => 'stopped',
  Ended(:final maybeEscaped) => 'stopped (warning: pids ${maybeEscaped.join(', ')} may have left its tree unseen)',
  Survived(:final pids, :final reason) => 'not closed: pids ${pids.join(', ')} $reason',
  ScanFailed(:final why) => 'not closed: its end could not be checked ($why)',
};

/// One process EveryAI started (or watches) for a session: what it runs, how
/// it ended, and where its whole output is kept.
final class ShellEntry {
  ShellEntry({
    required this.key,
    required this.id,
    required this.session,
    required this.command,
    required this.cwd,
    required this.origin,
    required this.background,
    this.description = '',
    this.pid,
    this.logPath,
    this.pty = false,
    LiveShell? live,
    DateTime? startedAt,
  }) : startedAt = startedAt ?? DateTime.now(),
       _live = live, // ignore: prefer_initializing_formals
       _state = ShellRunning(pid);

  /// Unique in the registry (a fork's shells share its parent's [session] and may reuse its ids).
  final String key;

  /// The id the agent uses (`bg_2`).
  final String id;
  final String session;
  final String command;
  final String cwd;
  final ShellOrigin origin;
  final String description;

  /// A background shell (else a foreground command, read-only once it ends).
  final bool background;

  /// The pid it was started with (kept after it ends, for the record).
  final int? pid;

  /// Its raw output on disk (see `ShellLog`), or null when nothing is kept.
  final String? logPath;

  /// Whether the output came from a pseudo-terminal (CRLF line ends already).
  final bool pty;
  final DateTime startedAt;

  ShellState _state;

  /// Where its process is (see [ShellState]); changed through [ShellRegistry.setState] and [ShellRegistry.follow].
  ShellState get state => _state;

  /// When it was seen to end (null while it runs or isn't closed).
  DateTime? get endedAt => switch (_state) {
    ShellExited(:final at) => at,
    _ => null,
  };

  /// Its exit code once it ended (null while it runs, isn't closed, or its code is unknown).
  int? get exitCode => switch (_state) {
    ShellExited(:final code) => code,
    _ => null,
  };

  /// When it last printed something (a workflow's stall check counts that as progress).
  DateTime? lastOutputAt;

  LiveShell? _live;

  /// Its live end while its process is there (null once it ended).
  LiveShell? get live => _state is ShellExited ? null : _live;
  set live(LiveShell? l) => _live = l;

  // Cancelled by the registry when the entry is trimmed or its session forgotten.
  // ignore: cancel_subscriptions
  StreamSubscription<ChildState>? _following;

  /// Runs its command again (a background shell the agent started; null otherwise).
  Future<void> Function()? restart;

  /// What the user typed into it that the agent hasn't been told about yet.
  final _typed = StringBuffer();

  /// Bytes written to its log so far (all of them, also those a roll dropped).
  int logged = 0;
  final _output = StreamController<({Uint8List bytes, int end})>.broadcast(sync: true);

  /// Its raw output as written to the log (CRLF line ends), from now on: each chunk with the [logged] count after
  /// it, so a view that read the log can skip what it already has. Delivered synchronously.
  Stream<({Uint8List bytes, int end})> get output => _output.stream;

  /// Called by whoever writes the log, right after writing [bytes] to it. An entry with no [logPath] keeps its
  /// newest output in memory instead ([memory]).
  void emit(Uint8List bytes) {
    logged += bytes.length;
    lastOutputAt = DateTime.now();
    if (logPath == null) {
      _memory.add(bytes);
      _memoryLength += bytes.length;
      while (_memoryLength > memoryCap && _memory.length > 1) {
        _memoryLength -= _memory.removeAt(0).length;
      }
    }
    if (_output.hasListener) _output.add((bytes: bytes, end: logged));
  }

  /// How much output an entry with no log file keeps.
  static const memoryCap = 2 * 1024 * 1024;
  final _memory = <Uint8List>[];
  var _memoryLength = 0;

  /// The output kept in memory (no log file): its newest [memoryCap] bytes.
  Uint8List get memory {
    final b = BytesBuilder(copy: false);
    _memory.forEach(b.add);
    return b.toBytes();
  }

  /// Whether its process may still be there: running, stopping, or not closed (see [notClosed]).
  bool get running => _state is! ShellExited;

  /// Whether a stop left it (or what it started) running.
  bool get notClosed => _state is ShellNotClosed;

  /// A label for tabs and rows: the description, else the command's start.
  String get title {
    final base = description.trim().isNotEmpty ? description.trim() : command.trim().split('\n').first;
    return base.length > 48 ? '${base.substring(0, 47)}…' : base;
  }

  /// Notes that the user sent [data] to the shell (kept for the agent's next read; capped).
  void noteTyped(String data) {
    if (_typed.length > 400) return;
    _typed.write(data);
  }

  /// What the user typed since the last call, readable (`rs⏎`), or null.
  String? takeTyped() {
    if (_typed.isEmpty) return null;
    final s = describeTyped(_typed.toString());
    _typed.clear();
    return s.isEmpty ? null : s;
  }
}

/// Every shell of every session, for the Processes tab, the terminal tabs
/// that follow one, and the tools that read them. One per app run.
final class ShellRegistry {
  ShellRegistry._();

  static final instance = ShellRegistry._();

  /// A registry of its own, for tests.
  @visibleForTesting
  factory ShellRegistry.forTest() => ShellRegistry._();

  final _bySession = <String, Map<String, ShellEntry>>{};
  final _changes = StreamController<String>.broadcast();

  /// The session whose shells changed (one started, ended, or got input).
  Stream<String> get changes => _changes.stream;

  /// The sessions with shells.
  Iterable<String> get sessions => _bySession.keys;

  /// [session]'s shells, oldest first.
  List<ShellEntry> of(String session) => [...?_bySession[session]?.values];

  ShellEntry? find(String session, String key) => _bySession[session]?[key];

  void add(ShellEntry e) {
    (_bySession[e.session] ??= {})[e.key] = e;
    _changes.add(e.session);
  }

  /// Marks [e] ended with [exitCode] (its own exit future said so).
  void ended(ShellEntry e, int exitCode) => setState(e, ShellExited(exitCode, DateTime.now()));

  /// Moves [e] to [state] (what its process's supervisor child says).
  void setState(ShellEntry e, ShellState state) {
    e._state = state;
    _changes.add(e.session);
  }

  /// Keeps [e]'s state with its supervisor child's: [now], then every change on [changes].
  void follow(ShellEntry e, ChildState now, Stream<ChildState> changes) {
    unawaited(e._following?.cancel());
    setState(e, shellStateOf(now));
    e._following = changes.listen((s) => setState(e, shellStateOf(s)));
  }

  void changed(ShellEntry e) => _changes.add(e.session);

  final _hints = <String, Set<String>>{};

  /// Container ids and names [session]'s commands printed or named (see `containerHintsOf`).
  Set<String> hintsOf(String session) => {...?_hints[session]};

  void addHints(String session, Set<String> hints) {
    if (hints.isEmpty) return;
    (_hints[session] ??= {}).addAll(hints);
  }

  /// Forgets [session]'s shells (the session was removed).
  void forget(String session) {
    final gone = _bySession.remove(session);
    if (gone == null) return;
    for (final e in gone.values) {
      unawaited(e._following?.cancel());
    }
    _changes.add(session);
  }

  /// Foreground commands kept per session (the oldest finished ones are forgotten; their logs stay on disk).
  static const keptForeground = 40;

  /// Drops the oldest finished foreground commands of [session] past [keptForeground].
  void trim(String session) {
    final m = _bySession[session];
    if (m == null) return;
    final done = [
      for (final e in m.values)
        if (!e.background && !e.running) e,
    ];
    for (final e in done.take(done.length - keptForeground < 0 ? 0 : done.length - keptForeground)) {
      m.remove(e.key);
      unawaited(e._following?.cancel());
    }
  }
}
