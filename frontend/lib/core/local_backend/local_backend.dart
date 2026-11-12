// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/foundation.dart';

import '../process/process_model.dart';

import 'local_backend_stub.dart' if (dart.library.io) 'local_backend_io.dart' as impl;

/// The EveryAI server bundled in the desktop app (backend-exp in local mode):
/// it runs chats on local models and on the user's own keys, so neither goes
/// through our deployed server. Loopback only; every request carries
/// [token] in `X-EveryAI-Local`.
final class LocalBackendInfo {
  const LocalBackendInfo({required this.baseUrl, required this.token});

  final Uri baseUrl;
  final String token;

  static const tokenHeader = 'X-EveryAI-Local';
}

/// Where the bundled server is in its life. Every change goes through [nextBackendPhase]:
///
/// ```text
///          start            ready
///   Idle ────────▶ Starting ──────▶ Running ──── exited ───▶ Crashed ── start (≤ 3 crashes a minute) ──▶ Starting
///    ▲               │ │ failed/exited │ stop
///    │               │ ▼               ▼
///    │               │ Unavailable  Stopping ── exited (checked ended) ──▶ Idle
///    │               │   │ start       │ notClosed (signalled, not seen to end)
///    │               │   ▼             ▼
///    │               │ Starting     NotClosed(reason) ── stop (retry) ──▶ Stopping
///    │               │ heldElsewhere
///    │               ▼
///    │         Blocked(reason) ── start (checks again) ──▶ Starting
///    └── Starting ◀── start (Crashed / Unavailable)
///   close (from any phase) ──▶ Closed: quit. Final: nothing starts again, so a request that comes in while the app
///   shuts down can't leave a fresh server running after it.
/// ```
///
/// Stopping ends only by the stop's own outcome: Idle when its process (and what it started) was checked gone,
/// NotClosed otherwise; never by a timer. A refused move asserts in debug builds and is recorded
/// ([refusedBackendTransitions]).
@immutable
sealed class BackendPhase {
  const BackendPhase();
}

final class BackendIdle extends BackendPhase {
  const BackendIdle();
  @override
  String toString() => 'Idle';
}

final class BackendStarting extends BackendPhase {
  const BackendStarting();
  @override
  String toString() => 'Starting';
}

final class BackendRunning extends BackendPhase {
  const BackendRunning(this.info);
  final LocalBackendInfo info;
  @override
  String toString() => 'Running(${info.baseUrl})';
}

final class BackendStopping extends BackendPhase {
  const BackendStopping();
  @override
  String toString() => 'Stopping';
}

/// A stop signalled it, but it (or what it started) wasn't seen to end, or that couldn't be checked: it may still
/// hold its port and database. Shown as not closed; a stop tries again; nothing new starts on its data meanwhile.
final class BackendNotClosed extends BackendPhase {
  const BackendNotClosed(this.reason);
  final String reason;
  @override
  String toString() => 'NotClosed($reason)';
}

/// Another EveryAI that is running uses this data folder's server (or one left behind couldn't be ended): this copy
/// starts no server of its own on the same database, and never kills the other one.
final class BackendBlocked extends BackendPhase {
  const BackendBlocked(this.reason);
  final String reason;
  @override
  String toString() => 'Blocked($reason)';
}

/// It exited without being asked.
final class BackendCrashed extends BackendPhase {
  const BackendCrashed(this.reason);
  final String reason;
  @override
  String toString() => 'Crashed($reason)';
}

/// It can't start (no binary in this build, it didn't answer).
final class BackendUnavailable extends BackendPhase {
  const BackendUnavailable(this.reason);
  final String reason;
  @override
  String toString() => 'Unavailable($reason)';
}

/// The app is quitting.
final class BackendClosed extends BackendPhase {
  const BackendClosed();
  @override
  String toString() => 'Closed';
}

@immutable
sealed class BackendEvent {
  const BackendEvent();
}

final class BackendStartAsked extends BackendEvent {
  const BackendStartAsked();
}

final class BackendReady extends BackendEvent {
  const BackendReady(this.info);
  final LocalBackendInfo info;
}

final class BackendStartFailed extends BackendEvent {
  const BackendStartFailed(this.reason);
  final String reason;
}

final class BackendStopAsked extends BackendEvent {
  const BackendStopAsked();
}

/// Its process ended ([reason] says how).
final class BackendExited extends BackendEvent {
  const BackendExited(this.reason);
  final String reason;
}

final class BackendCloseAsked extends BackendEvent {
  const BackendCloseAsked();
}

/// The stop's outcome wasn't a checked end ([outcome] says what is left).
final class BackendStopNotClosed extends BackendEvent {
  const BackendStopNotClosed(this.outcome);
  final KillOutcome outcome;
}

/// Its data folder is in use by a running server this run can't take over ([reason]).
final class BackendHeldElsewhere extends BackendEvent {
  const BackendHeldElsewhere(this.reason);
  final String reason;
}

/// The phase after [event], or null when [event] can't happen in [phase].
BackendPhase? nextBackendPhase(BackendPhase phase, BackendEvent event) => switch ((phase, event)) {
  (BackendClosed(), _) => null,
  (_, BackendCloseAsked()) => const BackendClosed(),
  (BackendIdle() || BackendCrashed() || BackendUnavailable(), BackendStartAsked()) => const BackendStarting(),
  (BackendStarting(), BackendReady(:final info)) => BackendRunning(info),
  (BackendStarting(), BackendStartFailed(:final reason) || BackendExited(:final reason)) => BackendUnavailable(reason),
  (BackendRunning(), BackendExited(:final reason)) => BackendCrashed(reason),
  (BackendRunning() || BackendStarting(), BackendStopAsked()) => const BackendStopping(),
  (BackendStopping(), BackendExited()) => const BackendIdle(),
  (BackendStopping(), BackendStopNotClosed(:final outcome)) => BackendNotClosed('$outcome'),
  (BackendNotClosed(), BackendStopAsked()) => const BackendStopping(),
  (BackendStarting(), BackendHeldElsewhere(:final reason)) => BackendBlocked(reason),
  (BackendBlocked(), BackendStartAsked()) => const BackendStarting(),
  _ => null,
};

/// One refused move, kept for tests and diagnostics.
typedef RefusedBackendTransition = ({BackendPhase from, BackendEvent event});

/// Every refused move since start (or since a test cleared it).
final refusedBackendTransitions = <RefusedBackendTransition>[];

/// Whether a refused move asserts (debug builds). Tests that check refusals turn it off.
@visibleForTesting
bool assertOnRefusedBackendTransition = true;

/// [nextBackendPhase], or (refused) the refusal recorded, logged and asserted in debug builds, and null.
BackendPhase? applyBackendEvent(BackendPhase from, BackendEvent event) {
  final next = nextBackendPhase(from, event);
  if (next != null) return next;
  refusedBackendTransitions.add((from: from, event: event));
  debugPrint('Refused bundled-server transition: $from + ${event.runtimeType}');
  assert(!assertOnRefusedBackendTransition, 'Refused bundled-server transition: $from + ${event.runtimeType}');
  return null;
}

/// Starts it (once per app run), restarts it when it dies, stops it on quit.
abstract interface class LocalBackend {
  /// The running server, started on first use. Null when this build has no
  /// bundled server (web, phones, a dev run without `tool/build_local_backend.sh`)
  /// or the app is quitting; [problem] then says why.
  Future<LocalBackendInfo?> ensureStarted();

  BackendPhase get phase;

  String? get problem;

  /// Whether it is up now (without starting it).
  bool get running;

  /// Stops it (verified: its process and what it started are checked gone); a later [ensureStarted] starts it
  /// again. The outcome is the stop's: anything but [Ended] leaves the phase at [BackendNotClosed].
  Future<KillOutcome> stop();

  /// Quit: lets it unload the models EveryAI loaded (within [unloadWithin]), stops it (verified), and never starts
  /// it again. The outcome is the stop's (logged as not closed when it isn't [Ended]).
  Future<KillOutcome> close({Duration unloadWithin = const Duration(seconds: 4)});
}

LocalBackend createLocalBackend() => impl.createLocalBackend();
