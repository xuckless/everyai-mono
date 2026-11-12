// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:io' show Platform, ProcessSignal;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_pty/flutter_pty.dart';

import 'supervisor.dart';

export 'package:flutter_pty/flutter_pty.dart' show Pty;

/// A program under a pseudo-terminal, held by the supervisor: [pty] for its terminal (output, input, size), [child]
/// for its life (states, the verified stop). Never signal [pty] itself: stop [child].
final class SupervisedPty {
  const SupervisedPty(this.pty, this.child);
  final Pty pty;
  final SupervisedChild child;
}

/// What `adopt`'s `startedWithin` allows beyond the time the start took (`lstart` has whole seconds).
const _adoptSlack = Duration(seconds: 5);

/// Starts [spec] under a pseudo-terminal ([rows] × [columns]) and hands it to [supervisor]: the one place a pty is
/// started (flutter_pty forks it, so the supervisor adopts it instead of spawning it).
///
/// Its environment is [spec]'s (on the app's when `includeParentEnvironment`) plus the tags of `spec.owner`; an
/// inherited `EVERYAI_SESSION` is dropped when the owner carries none (a user's terminal, the app's), so an agent's
/// Stop never matches it. It is adopted as the process just started (`startedWithin`), never a pid alone.
///
/// Throws what `Pty.start` throws (no pty library, no such program), and [SupervisorClosed] once the app quits,
/// after ending the pty at once (nothing would own it).
SupervisedPty spawnPty(ProcessSupervisor supervisor, SpawnSpec spec, {int rows = 25, int columns = 80}) {
  final tags = supervisor.tagsFor(spec.owner);
  final env = {if (spec.includeParentEnvironment) ...Platform.environment, ...spec.env, ...tags};
  if (!tags.containsKey(sessionTagEnvVar)) env.remove(sessionTagEnvVar);
  final startedAt = DateTime.now();
  final pty = Pty.start(
    spec.exe,
    arguments: spec.args,
    workingDirectory: spec.cwd,
    environment: env,
    rows: rows,
    columns: columns,
  );
  try {
    final child = supervisor.adopt(
      pty.pid,
      spec,
      exitCode: pty.exitCode,
      startedWithin: DateTime.now().difference(startedAt) + _adoptSlack,
    );
    return SupervisedPty(pty, _PtyChild(child, pty));
  } on SupervisorClosed {
    // Started while the app quits: it must not outlive it, and the supervisor takes nothing any more.
    pty.kill(ProcessSignal.sigkill);
    rethrow;
  }
}

/// The supervisor's child for a pty, with one fallback: should the adoption's check disown it (a check that
/// misjudged our own process), the pty still holds it. Its pid can't be reused until the pty has reaped it (its
/// exit code is pending until then), so while that exit isn't seen it stays live here, and [stop] ends it through
/// the pty (TERM, then KILL) and checks the exit: never "ended" for a program nobody signalled.
final class _PtyChild implements SupervisedChild {
  _PtyChild(this._inner, this._pty) {
    unawaited(
      _pty.exitCode.then((code) {
        _exit = code;
        _exitAt = DateTime.now();
        if (_inner.state is ChildDisowned) _states.add(state);
      }),
    );
    _inner.states.listen((_) => _states.add(state));
  }

  final SupervisedChild _inner;
  final Pty _pty;
  final _states = StreamController<ChildState>.broadcast(sync: true);
  final _at = DateTime.now();
  int? _exit;
  DateTime? _exitAt;

  /// The pty has reaped it.
  bool get _exited => _exit != null;

  @override
  int get id => _inner.id;
  @override
  SpawnSpec get spec => _inner.spec;

  @override
  ChildState get state => switch (_inner.state) {
    ChildDisowned(:final pid, :final why) when !_exited => ChildUnverified(
      pid,
      _at,
      'its check failed ($why); its terminal still holds it',
    ),
    ChildDisowned() => ChildExited(ExitCode(_exit!), _exitAt!),
    final s => s,
  };

  @override
  Stream<ChildState> get states => _states.stream;
  @override
  Future<ProcessIdentity> get landed => _inner.landed;
  @override
  Future<ExitSeen> get ended async {
    final seen = await _inner.ended;
    if (_inner.state is! ChildDisowned) return seen;
    return ExitCode(await _pty.exitCode);
  }

  @override
  int? get pid => _inner.pid ?? _pty.pid;
  @override
  int? get port => _inner.port;
  @override
  String? get detail => _inner.detail;
  @override
  void annotate({String? detail, int? port}) => _inner.annotate(detail: detail, port: port);

  @override
  bool signal(ProcessSignal signal) {
    if (_inner.state is ChildDisowned) return !_exited && _pty.kill(signal);
    return _inner.signal(signal);
  }

  @override
  Future<KillOutcome> stop({StopTimings? timings}) async {
    final out = await _inner.stop(timings: timings);
    if (_inner.state is! ChildDisowned || _exited) return out;
    // Disowned but still under its pty: the pid is still ours to signal (the pty hasn't reaped it).
    final p = _pty.pid;
    debugPrint('Process supervisor: ${spec.label} #$id was disowned but its pty still holds pid $p; ending it there.');
    for (final sig in [ProcessSignal.sigterm, ProcessSignal.sigkill]) {
      if (_exited) break;
      _pty.kill(sig);
      await _pty.exitCode.timeout(const Duration(seconds: 3), onTimeout: () => -1);
    }
    if (_exited) return Ended([p]);
    return Survived([p], 'did not end after SIGKILL through its terminal (its check had disowned it)');
  }
}
