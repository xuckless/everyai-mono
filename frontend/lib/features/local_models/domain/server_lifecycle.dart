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
///     │  │  │               │ start          │      Stopping(owner) ──notClosed──▶ NotClosed(owner, reason)
///     │  │  ▼               └──▶ Starting    │         │                              │ stop (retry) ▲ │
///     │  └─ Stopping ◀──────────────────────────────────┘ stopped                     ▼              │ │
///     │                                                                          Stopping ─notClosed─┘ │
///     └──────────── seenDown (Running: it went away by itself)          gone (its process seen ended) ─┘──▶ Stopped
/// ```
///
/// `seenUp` / `seenDown` are what a scan found: a server that answers is Running (an `outside` one unless EveryAI
/// started it), one that stopped answering is Stopped. A scan never interrupts Starting or Stopping, which end with
/// their own action's outcome. Stopped after a stop means its process is gone (checked by pid + start time); a stop
/// that signalled it but couldn't prove that ends in NotClosed, which only a retried stop or the process's seen end
/// ([ProcessGone]) leaves: a scan that no longer gets an answer doesn't make it closed. A refused move asserts in
/// debug builds and is recorded ([refusedServerTransitions]).
@immutable
sealed class ServerPhase {
  const ServerPhase();

  /// Start and Stop are off while an action runs.
  bool get busy => this is ServerStarting || this is ServerStopping;
}

/// A stop sent its signals, but the server's process (or something it started) still runs, or its end couldn't be
/// checked. Shown as not closed until a retried stop ends it or its end is seen.
final class ServerNotClosed extends ServerPhase {
  const ServerNotClosed(this.owner, this.reason);
  final ServerOwner owner;
  final String reason;
  @override
  bool operator ==(Object other) => other is ServerNotClosed && other.owner == owner && other.reason == reason;
  @override
  int get hashCode => Object.hash(5, owner, reason);
  @override
  String toString() => 'NotClosed(${owner.name}: $reason)';
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

/// The stop signalled it, but it (or what it started) wasn't seen to end.
final class StopNotClosed extends ServerEvent {
  const StopNotClosed(this.reason);
  final String reason;
}

/// Its process (one EveryAI started) was seen to end (its exit, or a check by pid + start time).
final class ProcessGone extends ServerEvent {
  const ProcessGone();
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
  (ServerStopping(:final owner), StopNotClosed(:final reason)) => ServerNotClosed(owner, reason),
  (ServerNotClosed(:final owner), StopAsked()) => ServerStopping(owner),
  (ServerNotClosed(), ProcessGone()) => const ServerStopped(),
  // Answering or not, its process still runs: only a stop or its seen end moves it.
  (ServerNotClosed(), SeenUp() || SeenDown()) => phase,
  // A process that ends by itself: the scan says so too, or will.
  (ServerRunning(owner: ServerOwner.everyai), ProcessGone()) => const ServerStopped(),
  (ServerRunning(owner: ServerOwner.outside), ProcessGone()) => phase,
  (ServerStarting() || ServerStopping() || ServerStopped() || ServerFailed(), ProcessGone()) => phase,
  _ => null,
};

/// One refused move, kept for tests and diagnostics.
typedef RefusedServerTransition = ({String server, ServerPhase from, ServerEvent event});

/// Every refused move since start (or since a test cleared it).
final refusedServerTransitions = <RefusedServerTransition>[];

/// Whether a refused move asserts (debug builds). Tests that check refusals turn it off.
@visibleForTesting
bool assertOnRefusedServerTransition = true;

/// Moves [from] by [event] for server [server], or records the refusal and returns null: a refused move is a bug in
/// the caller, so debug builds assert.
ServerPhase? applyServerEvent(String server, ServerPhase from, ServerEvent event) {
  final next = nextPhase(from, event);
  if (next != null) return next;
  refusedServerTransitions.add((server: server, from: from, event: event));
  debugPrint('Refused local-server transition ($server): $from + ${event.runtimeType}');
  assert(!assertOnRefusedServerTransition, 'Refused local-server transition ($server): $from + ${event.runtimeType}');
  return null;
}
