// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;

import '../../../core/process/supervisor.dart';

/// Short commands of the coding drivers, git and workflows (a CLI's `--version`, `auth status`, git, gh, a
/// notification): run through [ProcessSupervisor.runBounded], so a command that hangs is stopped (verified, with
/// what it started) when [timeout] runs out or [cancel] completes, and the answer says which ([RunResult]). A
/// quitting app ([SupervisorClosed]) reads as [StartFailed], like a program that isn't there.
Future<RunResult> runShort(
  String exe,
  List<String> args, {
  required Duration timeout,
  ProcessOwner owner = const ProbeOwner('cli'),
  Future<void>? cancel,
  Map<String, String> env = const {},
  bool includeParentEnvironment = true,
  String? cwd,
  String? stdin,
  List<int>? stdinBytes,
  Encoding encoding = lenientUtf8,
  Encoding? stderrEncoding,
  int? maxOutputBytes,
  String? label,
}) async {
  try {
    // In the root zone: the time limit and the supervisor's own timers are real time, also when the caller runs in
    // a fake-time zone (widget tests), where a fake minute could otherwise pass while git is still running.
    return await Zone.root.run(
      () => ProcessSupervisor.instance.runBounded(
        exe,
        args,
        timeout: timeout,
        cancel: cancel,
        owner: owner,
        env: env,
        includeParentEnvironment: includeParentEnvironment,
        cwd: cwd,
        stdin: stdin,
        stdinBytes: stdinBytes,
        stdoutEncoding: encoding,
        stderrEncoding: stderrEncoding ?? encoding,
        maxOutputBytes: maxOutputBytes,
        label: label,
      ),
    );
  } on SupervisorClosed catch (e) {
    return StartFailed('$e');
  }
}

/// UTF-8 that keeps going over bytes that aren't (a CLI's banner in another code page).
const lenientUtf8 = Utf8Codec(allowMalformed: true);

/// What went wrong with [r] in a sentence about [what] (`git status`, `codex --version`), or null when it finished
/// with exit code 0. A run that was stopped says whether the stop was proven.
String? runProblem(String what, RunResult r) => switch (r) {
  Finished(code: 0) => null,
  Finished(:final code, :final stderr) => '$what failed (exit $code)${_tail(stderr)}',
  TimedOut(:final kill) => '$what took too long and was stopped${_unproven(kill)}',
  Cancelled(:final kill) => '$what was cancelled${_unproven(kill)}',
  StartFailed(:final error) => "$what couldn't start: $error",
};

String _tail(String s) {
  final lines = s.trim().split('\n').where((l) => l.trim().isNotEmpty);
  return lines.isEmpty ? '.' : ': ${lines.last.trim()}';
}

String _unproven(KillOutcome kill) => switch (kill) {
  Ended() => '.',
  _ => ' (not proven ended: $kill).',
};

/// Says loudly (the log; a UI comes later) when [outcome], the stop of [what], isn't a proven end; returns it.
KillOutcome logStop(String what, KillOutcome outcome) {
  if (outcome is! Ended) debugPrint('EveryAI processes: $what did not close cleanly: $outcome');
  return outcome;
}

/// Runs [stop] and turns an error in it into an outcome (logged loudly), so a stop path never throws past its caller
/// and never says "ended" without proof.
Future<KillOutcome> stopChecked(String what, Future<KillOutcome> Function() stop) async {
  try {
    // In the root zone, like [runShort]: the stop's waits are real time.
    return logStop(what, await Zone.root.run(stop));
  } on Object catch (e) {
    return logStop(what, ScanFailed("couldn't stop it: $e"));
  }
}

/// One call in flight per key: a second caller while the first runs gets the same future; once it completes the
/// next call starts afresh. (Not `_m[k] ??= f().whenComplete(() => _m.remove(k))`: a future that is already
/// complete runs the removal before the assignment and the entry stays for good.)
final class SingleFlight<K, V> {
  final _running = <K, Future<V>>{};

  Future<V> run(K key, Future<V> Function() start) {
    if (_running[key] case final f?) return f;
    final f = start();
    _running[key] = f;
    f.then<void>((_) => _forget(key, f), onError: (Object _) => _forget(key, f)).ignore();
    return f;
  }

  bool isRunning(K key) => _running.containsKey(key);

  void _forget(K key, Future<V> f) {
    if (identical(_running[key], f)) _running.remove(key);
  }
}
