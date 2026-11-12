// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/process/supervisor.dart' show Ended, KillOutcome;
import '../harness/harness.dart' show HarnessError;
import 'short_run.dart' show stopChecked;

/// Where a session's CLI process is (its channel: a [LineChannel] or a JSON-RPC peer on one). Every change goes
/// through [nextLinkState]; a refused one is recorded ([refusedLinkMoves]) and asserts in debug builds.
///
/// ```text
///          spawn(g)              landed(g, c)                drop / gone(c)               stopped(c)
///   Idle ───────────▶ Spawning(g) ────────────▶ Live(g, c) ──────────────────▶ Stopping(c) ───────────▶ Idle
///    ▲                  │  │ spawnFailed(g)                                       │
///    │       drop       │  └──────────────▶ Idle                                  │
///    └──────────────────┘   (what lands later is stopped before anyone sees it)   │
///
///   Idle / Spawning / Live / Stopping ──close──▶ Closed (final; a live or landing process is stopped, verified)
/// ```
///
/// A process that lands after a drop or a close (its generation is no longer the one spawning) is stopped at once
/// and never becomes Live, so a close while starting leaves nothing running and nothing is started after a close. An
/// end of output (`gone`) is not taken for the process's exit: the process is stopped (verified) before the link is
/// Idle again, so a respawn never runs beside a process that only closed its stdout.
@immutable
sealed class LinkState<C> {
  const LinkState();
}

final class LinkIdle<C> extends LinkState<C> {
  const LinkIdle();
  @override
  String toString() => 'Idle';
}

final class LinkSpawning<C> extends LinkState<C> {
  const LinkSpawning(this.generation);
  final int generation;
  @override
  String toString() => 'Spawning($generation)';
}

final class LinkLive<C> extends LinkState<C> {
  const LinkLive(this.generation, this.channel);
  final int generation;
  final C channel;
  @override
  String toString() => 'Live($generation)';
}

final class LinkStopping<C> extends LinkState<C> {
  const LinkStopping(this.channel);
  final C channel;
  @override
  String toString() => 'Stopping';
}

final class LinkClosed<C> extends LinkState<C> {
  const LinkClosed();
  @override
  String toString() => 'Closed';
}

@immutable
sealed class LinkEvent<C> {
  const LinkEvent();
}

final class LinkSpawn<C> extends LinkEvent<C> {
  const LinkSpawn(this.generation);
  final int generation;
  @override
  String toString() => 'spawn($generation)';
}

final class LinkLanded<C> extends LinkEvent<C> {
  const LinkLanded(this.generation, this.channel);
  final int generation;
  final C channel;
  @override
  String toString() => 'landed($generation)';
}

final class LinkSpawnFailed<C> extends LinkEvent<C> {
  const LinkSpawnFailed(this.generation);
  final int generation;
  @override
  String toString() => 'spawnFailed($generation)';
}

final class LinkDrop<C> extends LinkEvent<C> {
  const LinkDrop();
  @override
  String toString() => 'drop';
}

/// Its output ended (stdout EOF): the process may still run.
final class LinkGone<C> extends LinkEvent<C> {
  const LinkGone(this.channel);
  final C channel;
  @override
  String toString() => 'gone';
}

/// The stop of [channel] came back (whatever its outcome: the outcome goes to the caller and the log).
final class LinkStopped<C> extends LinkEvent<C> {
  const LinkStopped(this.channel);
  final C channel;
  @override
  String toString() => 'stopped';
}

final class LinkClose<C> extends LinkEvent<C> {
  const LinkClose();
  @override
  String toString() => 'close';
}

/// What an event does in a state.
sealed class LinkStep<C> {
  const LinkStep();
}

final class LinkMoves<C> extends LinkStep<C> {
  const LinkMoves(this.next);
  final LinkState<C> next;
}

/// Nothing, on purpose (listed in the table): a stale landing or end, a second drop, anything after Closed.
final class LinkStays<C> extends LinkStep<C> {
  const LinkStays();
}

final class LinkRefused<C> extends LinkStep<C> {
  const LinkRefused();
}

/// The one transition table (see [LinkState]).
LinkStep<C> nextLinkState<C>(LinkState<C> from, LinkEvent<C> event) => switch ((from, event)) {
  (LinkIdle(), LinkSpawn(:final generation)) => LinkMoves(LinkSpawning(generation)),
  (LinkIdle(), LinkDrop() || LinkGone() || LinkStopped() || LinkLanded() || LinkSpawnFailed()) => LinkStays(),
  (LinkSpawning(generation: final g), LinkLanded(:final generation, :final channel)) when g == generation => LinkMoves(
    LinkLive(generation, channel),
  ),
  (LinkSpawning(generation: final g), LinkSpawnFailed(:final generation)) when g == generation => LinkMoves(LinkIdle()),
  (LinkSpawning(), LinkLanded() || LinkSpawnFailed() || LinkGone() || LinkStopped()) => LinkStays(),
  (LinkSpawning(), LinkDrop()) => LinkMoves(LinkIdle()),
  (LinkLive(channel: final c), LinkDrop()) => LinkMoves(LinkStopping(c)),
  (LinkLive(channel: final c), LinkGone(:final channel)) when identical(c, channel) => LinkMoves(LinkStopping(c)),
  (LinkLive(), LinkGone() || LinkStopped() || LinkLanded() || LinkSpawnFailed()) => LinkStays(),
  (LinkStopping(channel: final c), LinkStopped(:final channel)) when identical(c, channel) => LinkMoves(LinkIdle()),
  (LinkStopping(), LinkStopped() || LinkDrop() || LinkGone() || LinkLanded() || LinkSpawnFailed()) => LinkStays(),
  (LinkIdle() || LinkSpawning() || LinkLive() || LinkStopping(), LinkClose()) => LinkMoves(LinkClosed()),
  (LinkClosed(), _) => LinkStays(),
  _ => LinkRefused(),
};

typedef RefusedLinkMove = ({String label, Object from, Object event});

/// Every refused move since start (or since a test cleared it).
final refusedLinkMoves = <RefusedLinkMove>[];

/// Whether a refused move asserts (debug builds). Tests that check refusals turn it off.
@visibleForTesting
bool assertOnRefusedLinkMove = true;

LinkState<C> applyLinkEvent<C>(LinkState<C> from, LinkEvent<C> event, {String label = ''}) {
  switch (nextLinkState(from, event)) {
    case LinkMoves(:final next):
      return next;
    case LinkStays():
      return from;
    case LinkRefused():
      refusedLinkMoves.add((label: label, from: from, event: event));
      debugPrint('Refused driver link move ($label): $from + $event');
      assert(!assertOnRefusedLinkMove, 'Refused driver link move ($label): $from + $event');
      return from;
  }
}

/// A session's link to its CLI process ([LinkState]): starts it on demand ([ensure], one start at a time), ends it
/// verified ([drop], [gone], [close]) through [stopOf], and stops what lands after a drop or a close.
final class DriverLink<C extends Object> {
  DriverLink(this.label, this.stopOf);

  /// A link whose process is already running ([channel]).
  DriverLink.live(this.label, this.stopOf, C channel) : _state = LinkLive(0, channel);

  /// For the log ("Claude Code session 1234").
  final String label;

  /// Ends one process (its channel's verified close).
  final Future<KillOutcome> Function(C channel) stopOf;

  LinkState<C> _state = LinkIdle<C>();
  var _generation = 0;

  /// The start under way (Spawning).
  Future<C>? _landing;

  /// The stop under way (Stopping).
  Future<KillOutcome>? _stopping;

  /// The close, once asked.
  Future<KillOutcome>? _closing;

  /// For each start that was dropped or closed while it ran: the outcome of stopping what it made.
  final _abandoned = <int, Completer<KillOutcome>>{};

  LinkState<C> get state => _state;

  /// The live process's channel, or null.
  C? get live => switch (_state) {
    LinkLive(:final channel) => channel,
    _ => null,
  };

  bool get isClosed => _state is LinkClosed<C>;
  bool get isSpawning => _state is LinkSpawning<C>;

  void _move(LinkEvent<C> e) => _state = applyLinkEvent(_state, e, label: label);

  /// The live channel, starting one with [spawn] when there is none ([onLive] runs once it is Live, before any
  /// caller hears of it). A caller while it starts gets the same start; while the last one stops, the start waits
  /// for that stop. Throws [HarnessError] once closed, or when it was closed or dropped while it started.
  Future<C> ensure(Future<C> Function() spawn, {void Function(C channel)? onLive}) async {
    while (true) {
      switch (_state) {
        case LinkLive(:final channel):
          return channel;
        case LinkSpawning():
          return _landing!;
        case LinkClosed():
          throw HarnessError('$label is closed.');
        case LinkStopping():
          await _stopping;
        case LinkIdle():
          final g = ++_generation;
          _move(LinkSpawn(g));
          return _landing = _land(g, spawn, onLive);
      }
    }
  }

  Future<C> _land(int g, Future<C> Function() spawn, void Function(C channel)? onLive) async {
    final C c;
    try {
      c = await spawn();
    } on Object {
      _move(LinkSpawnFailed(g));
      _abandoned.remove(g)?.complete(const Ended([]));
      rethrow;
    }
    if (_state case LinkSpawning(generation: final now) when now == g) {
      _move(LinkLanded(g, c));
      onLive?.call(c);
      return c;
    }
    // Dropped or closed while it started: what it made never runs on.
    final outcome = await stopChecked('$label (started after it was closed)', () => stopOf(c));
    _abandoned.remove(g)?.complete(outcome);
    throw HarnessError('$label was closed while it started.');
  }

  /// Ends the process (or the one starting); the next [ensure] starts a new one. Its outcome (Ended when there was
  /// none).
  Future<KillOutcome> drop() {
    switch (_state) {
      case LinkLive(:final channel):
        _move(LinkDrop());
        return _stop(channel);
      case LinkSpawning(:final generation):
        _move(LinkDrop());
        return (_abandoned[generation] ??= Completer<KillOutcome>()).future;
      case LinkStopping():
        return _stopping!;
      case LinkClosed():
        return _closing ?? Future.value(const Ended([]));
      case LinkIdle():
        return Future.value(const Ended([]));
    }
  }

  /// [channel]'s output ended: the process is stopped (verified) before another may start. Stale ends (a channel
  /// that isn't the live one) change nothing.
  Future<KillOutcome> gone(C channel) {
    switch (_state) {
      case LinkLive(channel: final c) when identical(c, channel):
        _move(LinkGone(channel));
        return _stop(channel);
      case LinkStopping(channel: final c) when identical(c, channel):
        return _stopping!;
      default:
        _move(LinkGone(channel));
        return Future.value(const Ended([]));
    }
  }

  Future<KillOutcome> _stop(C channel) {
    final f = _stopping = stopChecked(label, () => stopOf(channel)).then((o) {
      _move(LinkStopped(channel));
      return o;
    });
    return f;
  }

  /// Closes for good: the process running, stopping or starting is stopped (verified); nothing starts after.
  Future<KillOutcome> close() => _closing ??= () {
    final before = _state;
    _move(const LinkClose());
    return switch (before) {
      LinkLive(:final channel) => stopChecked(label, () => stopOf(channel)),
      LinkStopping() => _stopping!,
      LinkSpawning(:final generation) => (_abandoned[generation] ??= Completer<KillOutcome>()).future,
      LinkIdle() || LinkClosed() => Future.value(const Ended([])),
    };
  }();
}
