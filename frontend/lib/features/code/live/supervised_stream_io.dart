// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../../../core/process/supervisor.dart';

/// Where one frame stream's helper process is. Every change goes through [nextStreamPhase]:
///
/// ```text
///   Idle ──listen──▶ Spawning(gen) ──spawned──▶ Streaming(child) ──cancel / ended──▶ Stopping ──outcome──▶ Stopped
///                       │ cancel                                                                      ▲
///                       ▼                                                                             │
///                    Stopping ── the spawn lands: its child is stopped too ───────────────────────────┘
///                       │ spawn failed
///   Spawning ──failed──▶ Stopped
/// ```
///
/// A cancel while the helper is being started doesn't drop it: the spawn that lands afterwards is stopped
/// (verified), so no stream helper outlives its listener.
sealed class StreamPhase {
  const StreamPhase();
}

final class StreamIdle extends StreamPhase {
  const StreamIdle();
}

final class StreamSpawning extends StreamPhase {
  const StreamSpawning(this.generation);
  final int generation;
}

final class StreamStreaming extends StreamPhase {
  const StreamStreaming(this.child);
  final SupervisedProcess child;
}

final class StreamStopping extends StreamPhase {
  const StreamStopping();
}

final class StreamStopped extends StreamPhase {
  const StreamStopped(this.outcome);
  final KillOutcome outcome;
}

sealed class StreamEvent {
  const StreamEvent();
}

final class StreamListened extends StreamEvent {
  const StreamListened(this.generation);
  final int generation;
}

final class StreamSpawned extends StreamEvent {
  const StreamSpawned(this.child);
  final SupervisedProcess child;
}

final class StreamSpawnFailed extends StreamEvent {
  const StreamSpawnFailed();
}

/// The listener cancelled, or the stream ended or failed.
final class StreamEnding extends StreamEvent {
  const StreamEnding();
}

final class StreamEnded extends StreamEvent {
  const StreamEnded(this.outcome);
  final KillOutcome outcome;
}

StreamPhase? nextStreamPhase(StreamPhase p, StreamEvent e) => switch ((p, e)) {
  (StreamIdle(), StreamListened(:final generation)) => StreamSpawning(generation),
  (StreamSpawning(), StreamSpawned(:final child)) => StreamStreaming(child),
  (StreamSpawning(), StreamSpawnFailed()) => const StreamStopped(Ended([])),
  (StreamSpawning() || StreamStreaming(), StreamEnding()) => const StreamStopping(),
  // A spawn that lands after the cancel is the stop's to end (handled where it lands).
  (StreamStopping(), StreamSpawned() || StreamSpawnFailed() || StreamEnding()) => p,
  (StreamStopping(), StreamEnded(:final outcome)) => StreamStopped(outcome),
  (StreamStopped(), StreamEnding()) => p,
  _ => null,
};

/// A broadcast-free stream of [frames] read from a helper started by [spawn] when listened to, and stopped
/// (verified) when the listener cancels or the output ends, including a helper whose start lands after the cancel.
/// [onPhase] sees each phase (tests).
Stream<Uint8List> supervisedFrames(
  String label,
  Future<SupervisedProcess> Function() spawn,
  StreamTransformer<List<int>, Uint8List> frames, {
  @visibleForTesting void Function(StreamPhase phase)? onPhase,
}) {
  StreamPhase phase = const StreamIdle();
  var generation = 0;
  SupervisedProcess? child;
  StreamSubscription<Uint8List>? sub;
  final stopped = Completer<KillOutcome>();
  late final StreamController<Uint8List> out;

  void move(StreamEvent e) {
    final next = nextStreamPhase(phase, e);
    if (next == null) {
      debugPrint('Refused stream transition ($label): $phase + $e');
      assert(false, 'Refused stream transition ($label): $phase + $e');
      return;
    }
    phase = next;
    onPhase?.call(next);
  }

  Future<void> end() async {
    if (phase is StreamStopping || phase is StreamStopped) {
      await stopped.future;
      return;
    }
    move(const StreamEnding());
    await sub?.cancel();
    // Spawning: the spawn's own end stops what it starts.
    if (child case final c?) {
      final outcome = await c.stop();
      if (outcome is! Ended) debugPrint('NOT CLOSED: $label: $outcome');
      move(StreamEnded(outcome));
      if (!stopped.isCompleted) stopped.complete(outcome);
    }
    await stopped.future;
    if (!out.isClosed) await out.close();
  }

  out = StreamController<Uint8List>(
    onListen: () async {
      final mine = ++generation;
      move(StreamListened(mine));
      final SupervisedProcess c;
      try {
        c = await spawn();
      } on Object catch (e) {
        if (phase is StreamStopping) {
          move(const StreamEnded(Ended([])));
          if (!stopped.isCompleted) stopped.complete(const Ended([]));
        } else {
          move(const StreamSpawnFailed());
          if (!stopped.isCompleted) stopped.complete(const Ended([]));
          if (!out.isClosed) {
            out.addError(e);
            await out.close();
          }
        }
        return;
      }
      child = c;
      unawaited(c.stderr.drain<void>().catchError((Object e) => debugPrint('$label stderr: $e')));
      if (phase is StreamStopping) {
        // Cancelled while it started: it must not run on.
        final outcome = await c.stop();
        if (outcome is! Ended) debugPrint('NOT CLOSED: $label (started after its cancel): $outcome');
        move(StreamEnded(outcome));
        if (!stopped.isCompleted) stopped.complete(outcome);
        return;
      }
      move(StreamSpawned(c));
      sub = c.stdout
          .transform(frames)
          .listen(
            out.add,
            onError: (Object e) {
              if (!out.isClosed) out.addError(e);
              unawaited(end());
            },
            onDone: () => unawaited(end()),
          );
    },
    onCancel: end,
  );
  return out.stream;
}
