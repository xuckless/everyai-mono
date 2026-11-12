// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io' show Platform, ProcessSignal;

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
    return SupervisedPty(pty, child);
  } on SupervisorClosed {
    // Started while the app quits: it must not outlive it, and the supervisor takes nothing any more.
    pty.kill(ProcessSignal.sigkill);
    rethrow;
  }
}
