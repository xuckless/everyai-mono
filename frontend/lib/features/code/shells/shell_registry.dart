// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

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
  Future<void> stop();
}

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
    this.live,
    DateTime? startedAt,
  }) : startedAt = startedAt ?? DateTime.now();

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
  int? pid;

  /// Its raw output on disk (see `ShellLog`), or null when nothing is kept.
  final String? logPath;

  /// Whether the output came from a pseudo-terminal (CRLF line ends already).
  final bool pty;
  final DateTime startedAt;
  DateTime? endedAt;

  /// When it last printed something (a workflow's stall check counts that as progress).
  DateTime? lastOutputAt;
  int? exitCode;

  /// Set while it runs and we hold its ends.
  LiveShell? live;

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

  bool get running => endedAt == null;

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

  /// Marks [e] ended with [exitCode].
  void ended(ShellEntry e, int exitCode) {
    e
      ..exitCode = exitCode
      ..endedAt = DateTime.now()
      ..live = null;
    _changes.add(e.session);
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
    if (_bySession.remove(session) != null) _changes.add(session);
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
    }
  }
}
