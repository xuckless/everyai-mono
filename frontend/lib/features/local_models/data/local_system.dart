// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/foundation.dart';

import '../../../core/process/process_model.dart';
import '../../../core/process/supervisor.dart' show DetachedLaunch;
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

  /// A line to show beside the stop when processes that may have been started by it were left alone (their
  /// environment can't be read); null when there are none.
  String? get warning => switch (outcome) {
    Ended(:final maybeEscaped) when maybeEscaped.isNotEmpty =>
      'Stopped; processes that may be its were left alone (pid ${maybeEscaped.join(', ')}).',
    _ => null,
  };
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

  /// Runs a short command ([timeout] at most, 10 s by default; one that takes longer is killed, and the output then
  /// says so with exit -1): its exit code and output, null when it couldn't run. [duringQuit] lets a goodbye command
  /// (`lms server stop`, quitting Ollama.app) run while the app quits.
  Future<({int code, String out})?> run(
    String exe,
    List<String> args, {
    bool duringQuit = false,
    Duration timeout = const Duration(seconds: 10),
  });

  /// Starts [exe] [args] meant to outlive the app: untagged (no `EVERYAI_*` variables), detached stdio, in no group
  /// of ours, never listed, swept or stopped by the app. For a program that may start a user's own app (`lms server
  /// start` can launch LM Studio's daemon), which no cleanup of ours may then reach.
  Future<DetachedLaunch> launchDetached(String exe, List<String> args);

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

/// The file names [command] (a process table's command line) may run as, lower case with `.exe` dropped: argv0's
/// base name tried at each space before the first option (a path may hold spaces:
/// `/Applications/LM Studio.app/Contents/MacOS/LM Studio`), plus the module of `python -m <module>` or the script an
/// interpreter runs.
Set<String> commandProgramNames(String command) {
  String base(String s) {
    var n = s.replaceAll(RegExp('''^["']|["']\$'''), '').split(RegExp(r'[/\\]')).last.toLowerCase();
    if (n.endsWith('.exe')) n = n.substring(0, n.length - 4);
    return n;
  }

  final words = command.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  final names = <String>{};
  var prefix = '';
  for (final w in words) {
    if (w.startsWith('-') && prefix.isNotEmpty) break;
    prefix = prefix.isEmpty ? w : '$prefix $w';
    final n = base(prefix);
    if (n.isNotEmpty) names.add(n);
  }
  if (words.isNotEmpty && RegExp(r'^(python[0-9.]*|uv|uvx|node|deno|bun)$').hasMatch(base(words.first))) {
    for (var i = 1; i < words.length; i++) {
      final w = words[i];
      if (w == '-m' && i + 1 < words.length) {
        names.add(words[i + 1].split('.').first.toLowerCase());
        break;
      }
      if (w == 'run' || w.startsWith('-')) continue;
      names.add(base(w));
      break;
    }
  }
  return names;
}

/// Whether [command] (a listener's command line) is [server]'s kind of program, so a stop may end it: Ollama,
/// LM Studio, llama.cpp's server, MLX, vLLM, Jan, or the program of a manual server's start command. Matched on the
/// program's file name ([commandProgramNames]), never on a word anywhere in the line: an `ssh -L … ollama-box`
/// tunnel or a program under `/Users/janet/` is not a server. Anything else (another app that happens to hold the
/// port) is never stopped.
bool listenerMatches(LocalServer server, String command) {
  final names = commandProgramNames(command);
  bool any(bool Function(String n) f) => names.any(f);
  return switch (server.kind) {
    LocalServerKind.ollama => any((n) => n == 'ollama' || n == 'ollama app'),
    LocalServerKind.lmstudio => any(
      (n) => n == 'lms' || n == 'lmstudio' || n == 'llmster' || n.startsWith('lm studio'),
    ),
    LocalServerKind.llamacpp => any((n) => n == 'llama-server' || n == 'llama_cpp'),
    LocalServerKind.mlx => any((n) => n.startsWith('mlx')),
    LocalServerKind.vllm => any((n) => n == 'vllm'),
    LocalServerKind.jan => any((n) => n == 'jan' || n.startsWith('cortex')),
    LocalServerKind.fm => any((n) => n == 'fm'),
    LocalServerKind.custom => switch (server.startCommand == null ? null : startCommandProgram(server.startCommand!)) {
      final p? => names.contains(p.toLowerCase().replaceAll(RegExp(r'\.exe$'), '')),
      null => false,
    },
  };
}
