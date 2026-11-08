// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/foundation.dart';

/// Who started a running server: EveryAI (it stops it at quit) or something else (the user, the server's own app;
/// left running at quit, though the user may stop it from EveryAI).
enum ServerOwner { everyai, outside }

/// Where one local model server is in its life. Every change goes through [nextPhase]:
///
/// ```text
///             start                started(owner)
///   Stopped ─────────▶ Starting ──────────────────▶ Running(owner)
///     ▲  ▲               │  │ startFailed              │      ▲
///     │  │      stop     │  ▼                     stop │      │ stopFailed
///     │  │  ┌────────────┘ Failed(reason) ◀─┐         ▼      │
///     │  │  │               │ start          │      Stopping(owner)
///     │  │  ▼               └──▶ Starting    │         │
///     │  └─ Stopping ◀──────────────────────────────────┘ stopped / seenDown
///     └──────────── seenDown (Running: it went away by itself)
/// ```
///
/// `seenUp` / `seenDown` are what a scan found: a server that answers is Running (an `outside` one unless EveryAI
/// started it), one that stopped answering is Stopped. A scan never interrupts Starting or Stopping, which end with
/// their own action's outcome.
@immutable
sealed class ServerPhase {
  const ServerPhase();

  /// Start and Stop are off while an action runs.
  bool get busy => this is ServerStarting || this is ServerStopping;
}

final class ServerStopped extends ServerPhase {
  const ServerStopped();
  @override
  bool operator ==(Object other) => other is ServerStopped;
  @override
  int get hashCode => 0;
  @override
  String toString() => 'Stopped';
}

final class ServerStarting extends ServerPhase {
  const ServerStarting();
  @override
  bool operator ==(Object other) => other is ServerStarting;
  @override
  int get hashCode => 1;
  @override
  String toString() => 'Starting';
}

final class ServerRunning extends ServerPhase {
  const ServerRunning(this.owner);
  final ServerOwner owner;
  @override
  bool operator ==(Object other) => other is ServerRunning && other.owner == owner;
  @override
  int get hashCode => Object.hash(2, owner);
  @override
  String toString() => 'Running(${owner.name})';
}

final class ServerStopping extends ServerPhase {
  const ServerStopping(this.owner);

  /// Who it belonged to, so a stop that fails goes back to the same Running.
  final ServerOwner owner;
  @override
  bool operator ==(Object other) => other is ServerStopping && other.owner == owner;
  @override
  int get hashCode => Object.hash(3, owner);
  @override
  String toString() => 'Stopping(${owner.name})';
}

final class ServerFailed extends ServerPhase {
  const ServerFailed(this.reason);
  final String reason;
  @override
  bool operator ==(Object other) => other is ServerFailed && other.reason == reason;
  @override
  int get hashCode => Object.hash(4, reason);
  @override
  String toString() => 'Failed($reason)';
}

@immutable
sealed class ServerEvent {
  const ServerEvent();
}

/// The user (or the app, for Apple's server) asked to start it.
final class StartAsked extends ServerEvent {
  const StartAsked();
}

/// It answers now.
final class Started extends ServerEvent {
  const Started(this.owner);
  final ServerOwner owner;
}

final class StartFailed extends ServerEvent {
  const StartFailed(this.reason);
  final String reason;
}

final class StopAsked extends ServerEvent {
  const StopAsked();
}

/// It no longer answers after a stop.
final class StopDone extends ServerEvent {
  const StopDone();
}

final class StopFailed extends ServerEvent {
  const StopFailed(this.reason);
  final String reason;
}

/// A scan found it answering; [owner] is who started it.
final class SeenUp extends ServerEvent {
  const SeenUp(this.owner);
  final ServerOwner owner;
}

/// A scan found it not answering (or the process EveryAI started exited).
final class SeenDown extends ServerEvent {
  const SeenDown();
}

/// The phase after [event], or null when [event] can't happen in [phase] (the caller ignores it).
ServerPhase? nextPhase(ServerPhase phase, ServerEvent event) => switch ((phase, event)) {
  (ServerStopped() || ServerFailed(), StartAsked()) => const ServerStarting(),
  (ServerStopped() || ServerFailed(), SeenUp(:final owner)) => ServerRunning(owner),
  (ServerStopped(), SeenDown()) => const ServerStopped(),
  (ServerFailed(), SeenDown()) => phase,
  (ServerStarting(), Started(:final owner)) => ServerRunning(owner),
  (ServerStarting(), StartFailed(:final reason)) => ServerFailed(reason),
  // A start can be called off: what it launched is stopped.
  (ServerStarting(), StopAsked()) => const ServerStopping(ServerOwner.everyai),
  (ServerStarting() || ServerStopping(), SeenUp() || SeenDown()) => phase,
  (ServerRunning(:final owner), StopAsked()) => ServerStopping(owner),
  (ServerRunning(), SeenUp(:final owner)) => ServerRunning(owner),
  (ServerRunning(), SeenDown()) => const ServerStopped(),
  (ServerStopping(), StopDone()) => const ServerStopped(),
  (ServerStopping(:final owner), StopFailed()) => ServerRunning(owner),
  _ => null,
};
