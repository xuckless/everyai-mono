// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/foundation.dart';

import '../../../core/process/process_model.dart';
import '../domain/fm.dart';
import '../domain/hardware.dart';
import '../domain/local_server.dart';
import 'local_system_stub.dart' if (dart.library.io) 'local_system_io.dart' as impl;

/// A server process EveryAI launched: [exited] completes with its exit code.
final class LaunchedServer {
  const LaunchedServer({required this.pid, required this.exited});
  final int pid;
  final Future<int> exited;
}

/// What a stop of a model server did. Only [ServerStopEnded] means it is gone (checked by pid + start time).
@immutable
sealed class ServerStopResult {
  const ServerStopResult();

  /// Why it isn't stopped, in plain words; null when it is.
  String? get problem;
}

/// It is gone (or nothing was running); [outcome] is what the stop ended.
final class ServerStopEnded extends ServerStopResult {
  const ServerStopEnded([this.outcome = const Ended([])]);
  final KillOutcome outcome;
  @override
  String? get problem => null;
  @override
  String toString() => 'ServerStopEnded($outcome)';
}

/// Signals were sent, but it (or something it started) still runs, or that couldn't be checked: not closed.
final class ServerStopNotClosed extends ServerStopResult {
  const ServerStopNotClosed(this.outcome);
  final KillOutcome outcome;
  @override
  String get problem => switch (outcome) {
    Survived(:final pids) => 'Not closed: still running after SIGKILL (pid ${pids.join(', ')}).',
    Unaccounted(:final candidates, :final reason) => 'Not closed: $reason (pid ${candidates.join(', ')}).',
    ScanFailed(:final why) => "Not closed: its end couldn't be checked ($why).",
    Ended() => 'Not closed.',
  };
  @override
  String toString() => 'ServerStopNotClosed($outcome)';
}

/// Not tried: nothing was signalled ([reason] says why, and who owns the port when that is the reason).
final class ServerStopRefused extends ServerStopResult {
  const ServerStopRefused(this.reason, {this.owner});
  final String reason;

  /// The command line of what listens on the port, when that is why.
  final String? owner;
  @override
  String get problem => reason;
  @override
  String toString() => 'ServerStopRefused($reason)';
}

/// What the local-model code needs from the computer: its hardware, the server programs, and the server processes
/// (the ones EveryAI launched, by server id, and the ones it finds listening on a port). Tests replace it.
abstract interface class LocalSystem {
  HostOs get os;

  Future<HardwareSpec> hardware();

  /// Where `ollama` is installed, null when it isn't.
  Future<String?> ollamaPath();

  /// Where LM Studio's `lms` command is, null when it isn't installed.
  Future<String?> lmsPath();

  Future<FmStatus> fmStatus();

  /// Runs a short command (10 s at most; one that takes longer is killed, and the output then says so): its exit
  /// code and output, null when it couldn't run.
  Future<({int code, String out})?> run(String exe, List<String> args);

  /// Launches the server [id] ([exe] [args]; through `/bin/sh -c` as the leader of its own process group when
  /// [shell], for a user's own start command); its output goes to [logPath] when given; [port] is the port it
  /// serves (kept in the process ledger, so a relaunch knows it). Null when it couldn't start; [launchProblem] says
  /// why. One process per id.
  Future<LaunchedServer?> launch(
    String id,
    String exe,
    List<String> args, {
    Map<String, String> env = const {},
    bool shell = false,
    String? logPath,
    int? port,
  });

  String? get launchProblem;

  /// Whether EveryAI launched the server [id] and its process still runs (the process supervisor's registry, so a
  /// relaunch of the same run still knows its own).
  bool owns(String id);

  /// The port the server [id] EveryAI launched serves, while it runs.
  int? ownedPort(String id);

  /// Ends the process EveryAI launched for [id] and everything it started (verified).
  Future<ServerStopResult> stopOwned(String id, {Duration grace = const Duration(seconds: 5)});

  /// Ends what listens on [port] for [server] (one EveryAI didn't start): only on a loopback address, and only when
  /// the listener's command is [server]'s kind of program (else a [ServerStopRefused] naming its command); never
  /// this app or its own children. Every signal is sent only while the listener's pid has the start time it was
  /// checked with.
  Future<ServerStopResult> stopListener(
    LocalServer server, {
    required int port,
    Duration grace = const Duration(seconds: 5),
  });

  /// A free loopback port, null when none could be had.
  Future<int?> freePort();

  /// Ends every server EveryAI launched (quit, or before the bundled server goes), merged.
  Future<KillOutcome> stopAllOwned();

  /// Where server logs go (app data `local-servers/`), null when there's none.
  Future<String?> logDir();
}

LocalSystem createLocalSystem() => impl.createLocalSystem();

/// True inside `flutter test` (which sets FLUTTER_TEST): app-wide providers then don't probe this computer's ports
/// and programs unless a test asks for it.
bool get runningUnderTest => impl.runningUnderTest;

/// Whether [baseUrl] is on this computer's loopback (`localhost`, 127.x, ::1).
bool isLoopbackUrl(String baseUrl) {
  final host = Uri.tryParse(baseUrl)?.host.toLowerCase();
  if (host == null || host.isEmpty) return false;
  if (host == 'localhost' || host == '::1' || host == '[::1]') return true;
  final parts = host.split('.');
  return parts.length == 4 && parts.first == '127' && parts.every((p) => int.tryParse(p) != null);
}

/// The program a user's start command runs (its first word after `exec` and `VAR=value` assignments), as a file
/// name: `llama-server` for `exec /opt/bin/llama-server -m x`. Null when there is none.
String? startCommandProgram(String command) {
  final words = command.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  var i = 0;
  while (i < words.length && (words[i] == 'exec' || RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=').hasMatch(words[i]))) {
    i++;
  }
  if (i >= words.length) return null;
  final w = words[i].replaceAll(RegExp('''^["']|["']\$'''), '');
  final name = w.split(RegExp(r'[/\\]')).last;
  return name.isEmpty ? null : name;
}

/// Whether [command] (a listener's command line) is [server]'s kind of program, so a stop may end it: Ollama,
/// LM Studio, llama.cpp's server, MLX, vLLM, Jan, or the program of a manual server's start command. Anything else
/// (another app that happens to hold the port) is never stopped.
bool listenerMatches(LocalServer server, String command) {
  final c = command.toLowerCase();
  bool has(String s) => c.contains(s);
  return switch (server.kind) {
    LocalServerKind.ollama => has('ollama'),
    LocalServerKind.lmstudio => has('lm studio') || has('lmstudio') || has('lms ') || c.endsWith('/lms'),
    LocalServerKind.llamacpp => has('llama-server') || has('llama.cpp') || has('llama_cpp'),
    LocalServerKind.mlx => has('mlx'),
    LocalServerKind.vllm => has('vllm'),
    LocalServerKind.jan => has('jan') || has('cortex'),
    LocalServerKind.fm => c.contains('/fm ') || c.endsWith('/fm') || c.startsWith('fm '),
    LocalServerKind.custom => switch (server.startCommand == null ? null : startCommandProgram(server.startCommand!)) {
      final p? => c.split(RegExp(r'\s+')).any((w) => w.split(RegExp(r'[/\\]')).last.toLowerCase() == p.toLowerCase()),
      null => false,
    },
  };
}
