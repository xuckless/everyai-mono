// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';

import 'package:flutter/foundation.dart';

// Capped pools of heavy live resources (a browser page, a simulator, an emulator, a stream, a display) and of
// running sessions. Pure: no dart:io, so the web build and tests use it as it is. The owner of each pool
// (`features/code/live/live_pool.dart`) starts and ends the resources; this file only decides whose turn it is.
//
// Owner's rules: a FIFO queue per kind; a full pool queues (never refuses); an idle holder is NEVER evicted, it is
// nudged (its next tool result says others wait); the user's own Preview is a holder like any other and is never
// nudged.

/// What a pool hands out.
enum ResourceKind {
  browser('browser'),
  simulator('simulator'),
  emulator('emulator'),
  stream('stream'),
  display('display'),
  session('session');

  const ResourceKind(this.label);

  /// The name in texts ("Queued for a browser").
  final String label;

  /// The Preferences key of its capacity.
  String get prefKey => 'code.pool.$name';
}

/// A lease's lifecycle.
///
/// ```
///   Queued(position) ──► Granted ──► Active ⇄ Idle
///      │  ▲   │             │          │       │
///      │  └───┘ (moves up)  └──────────┴───────┴──► Releasing ──► Released
///      │                                                   └─────► Failed(reason)
///      └──► Released (left the queue: released, or its ticket ran out)
/// ```
/// Every live state may also go to Failed (the resource couldn't be made). Released and Failed are final.
@immutable
sealed class LeaseState {
  const LeaseState();

  /// Released or Failed: nothing more happens to it.
  bool get ended => this is Released || this is Failed;

  /// Holds a slot (granted, in use, idle or being released).
  bool get holdsSlot => this is Granted || this is Active || this is Idle || this is Releasing;
}

final class Queued extends LeaseState {
  const Queued(this.position, this.since);

  /// 1 for the head of the queue.
  final int position;
  final DateTime since;
  @override
  String toString() => 'Queued($position)';
}

final class Granted extends LeaseState {
  const Granted(this.at);
  final DateTime at;
  @override
  String toString() => 'Granted';
}

final class Active extends LeaseState {
  const Active(this.lastUsed);
  final DateTime lastUsed;
  @override
  String toString() => 'Active';
}

final class Idle extends LeaseState {
  const Idle(this.since);

  /// The last use.
  final DateTime since;
  @override
  String toString() => 'Idle';
}

final class Releasing extends LeaseState {
  const Releasing();
  @override
  String toString() => 'Releasing';
}

final class Released extends LeaseState {
  const Released();
  @override
  String toString() => 'Released';
}

final class Failed extends LeaseState {
  const Failed(this.reason);
  final String reason;
  @override
  String toString() => 'Failed($reason)';
}

/// Whether a lease may move from [from] to [to] (the diagram on [LeaseState]).
bool leaseEdge(LeaseState from, LeaseState to) => switch ((from, to)) {
  (Released() || Failed(), _) => false,
  (_, Failed()) => true,
  (Queued(), Queued() || Granted() || Released()) => true,
  (Granted(), Active() || Idle() || Releasing()) => true,
  (Active(), Active() || Idle() || Releasing()) => true,
  (Idle(), Active() || Releasing()) => true,
  (Releasing(), Released()) => true,
  _ => false,
};

/// A refused move, kept for tests and logs.
typedef RefusedLeaseMove = ({int lease, LeaseState from, LeaseState to});

/// One holder's ticket for one [kind]. Its [state] is the pool's to change.
final class Lease {
  Lease._(this.id, this.holder, this.kind, this._state, this._lastCall);

  final int id;

  /// Who holds it: `agent:<session>`, `user:<session>` (the Preview), `session:<id>`.
  final String holder;
  final ResourceKind kind;
  LeaseState _state;
  DateTime _lastCall;

  LeaseState get state => _state;

  /// The holder's last call (a queued ticket is kept [Pool.ticketKeep] after it).
  DateTime get lastCall => _lastCall;

  /// Whether this is the user's own (the Preview): never nudged.
  bool get isUser => holder.startsWith('user:');

  @override
  String toString() => 'Lease($id, $holder, ${kind.name}, $_state)';
}

/// The browser/simulator/... capacities picked from this machine's RAM (GB) and cores.
Map<ResourceKind, int> autoCapacity({required double ramGb, required int cores}) {
  final browser = ((ramGb - 4) / 2).floor().clamp(2, 8);
  return {
    ResourceKind.browser: browser,
    ResourceKind.simulator: ramGb < 32 ? 1 : 2,
    ResourceKind.emulator: ramGb < 32 || cores < 8 ? 1 : 2,
    ResourceKind.stream: 4,
    ResourceKind.display: browser,
    ResourceKind.session: cores.clamp(4, 16),
  };
}

/// Capacities until the machine is read: the smallest machine's.
final Map<ResourceKind, int> fallbackCapacity = autoCapacity(ramGb: 8, cores: 4);

/// Capped FIFO pools, one per [ResourceKind]. Listen to it for any change.
final class Pool extends ChangeNotifier {
  Pool({
    Map<ResourceKind, int>? capacity,
    DateTime Function()? clock,
    this.ticketKeep = const Duration(minutes: 2),
    this.idleAfter = const Duration(minutes: 2),
  }) : _now = clock ?? DateTime.now,
       _capacity = {...fallbackCapacity, ...?capacity};

  final DateTime Function() _now;
  final Map<ResourceKind, int> _capacity;

  /// How long a queued ticket keeps its place without a call.
  final Duration ticketKeep;

  /// How long unused before a holder counts as idle.
  final Duration idleAfter;

  final _leases = <int, Lease>{};
  final _queues = {for (final k in ResourceKind.values) k: <Lease>[]};
  var _next = 0;

  /// Moves the table refused (each also asserts in debug).
  final refused = <RefusedLeaseMove>[];

  int capacity(ResourceKind kind) => _capacity[kind]!;

  /// Changes [kind]'s capacity (at least 1); a larger one grants the head of the queue at once. Holders above a
  /// smaller one keep their slot (never evicted) and the queue waits until they release.
  void setCapacity(ResourceKind kind, int n) {
    _capacity[kind] = n < 1 ? 1 : n;
    _grantFree(kind);
    notifyListeners();
  }

  Map<ResourceKind, int> get capacities => Map.unmodifiable(_capacity);

  /// The leases holding a slot of [kind].
  List<Lease> holders(ResourceKind kind) => [
    for (final l in _leases.values)
      if (l.kind == kind && l.state.holdsSlot) l,
  ];

  /// [kind]'s queue, head first.
  List<Lease> queued(ResourceKind kind) => List.unmodifiable(_queues[kind]!);

  /// The live lease [holder] has for [kind], or null.
  Lease? leaseOf(String holder, ResourceKind kind) {
    _expire(kind);
    return _leases.values.where((l) => l.holder == holder && l.kind == kind && !l.state.ended).firstOrNull;
  }

  /// [holder]'s ticket for [kind]: its existing one (a call refreshes a queued ticket), else a new one, granted at
  /// once when a slot is free and nobody waits, else queued at the back.
  Lease acquire(String holder, ResourceKind kind) {
    final now = _now();
    if (leaseOf(holder, kind) case final l?) {
      l._lastCall = now;
      return l;
    }
    final q = _queues[kind]!;
    final free = holders(kind).length < capacity(kind) && q.isEmpty;
    final l = Lease._(++_next, holder, kind, free ? Granted(now) : Queued(q.length + 1, now), now);
    _leases[l.id] = l;
    if (!free) q.add(l);
    notifyListeners();
    return l;
  }

  /// [lease] was used now (any call on the resource). A queued ticket only keeps its place.
  void touch(Lease lease) {
    final now = _now();
    lease._lastCall = now;
    if (lease.state case Granted() || Active() || Idle()) _to(lease, Active(now));
    notifyListeners();
  }

  /// 1-based place in the queue, or null when not queued.
  int? position(Lease lease) => switch (lease.state) {
    Queued(:final position) => position,
    _ => null,
  };

  /// Starts releasing [lease] (its resource is being closed); [finishRelease] ends it. A queued ticket just leaves.
  void beginRelease(Lease lease) {
    if (lease.state is Queued) {
      _to(lease, const Released());
      _dequeue(lease);
    } else if (lease.state is! Releasing && !lease.state.ended) {
      _to(lease, const Releasing());
    }
    notifyListeners();
  }

  /// Ends a release: Released, or Failed with [failure] (the resource didn't close; said loudly by the owner). The
  /// slot goes to the head of the queue either way: the owner has stopped what it could.
  void finishRelease(Lease lease, {String? failure}) {
    if (lease.state is Releasing) _to(lease, failure == null ? const Released() : Failed(failure));
    _leases.remove(lease.id);
    _grantFree(lease.kind);
    notifyListeners();
  }

  /// [beginRelease] then [finishRelease].
  void release(Lease lease, {String? failure}) {
    beginRelease(lease);
    finishRelease(lease, failure: failure);
  }

  /// The resource couldn't be made: the lease fails and its slot is free again.
  void fail(Lease lease, String reason) {
    _to(lease, Failed(reason));
    _dequeue(lease);
    _leases.remove(lease.id);
    _grantFree(lease.kind);
    notifyListeners();
  }

  /// Completes true once [lease] holds a slot, false when [timeout] (null: none) passes first or it ends. The
  /// ticket is kept.
  Future<bool> waitGranted(Lease lease, Duration? timeout) {
    if (lease.state.holdsSlot) return Future.value(true);
    if (lease.state.ended || (timeout != null && timeout <= Duration.zero)) return Future.value(false);
    final done = Completer<bool>();
    void check() {
      if (done.isCompleted) return;
      if (lease.state.holdsSlot) done.complete(true);
      if (lease.state.ended) done.complete(false);
    }

    addListener(check);
    final timer = timeout == null
        ? null
        : Timer(timeout, () {
            if (!done.isCompleted) done.complete(false);
          });
    return done.future.whenComplete(() {
      timer?.cancel();
      removeListener(check);
    });
  }

  /// The owner's nudge for [lease]'s holder, or null: when it hasn't used the resource for [idleAfter] or more and
  /// someone waits behind it. Never for the user's own lease. Nobody is ever evicted.
  String? nudgeFor(Lease lease, [DateTime? now]) {
    final at = now ?? _now();
    _markIdle(lease.kind, at);
    if (lease.isUser) return null;
    final since = switch (lease.state) {
      Idle(:final since) => since,
      _ => null,
    };
    final behind = _queues[lease.kind]!.length;
    if (since == null || behind == 0) return null;
    final mins = at.difference(since).inMinutes;
    return "It seems you haven't used the ${lease.kind.label} for $mins min; $behind "
        "${behind == 1 ? 'agent is' : 'agents are'} behind you in the queue. Close it (action close) if you are done.";
  }

  // ---------------------------------------------------------------- internals

  void _to(Lease l, LeaseState next) {
    if (!leaseEdge(l._state, next)) {
      refused.add((lease: l.id, from: l._state, to: next));
      assert(false, 'Lease ${l.id}: refused ${l._state} -> $next');
      return;
    }
    l._state = next;
  }

  void _dequeue(Lease l) {
    final q = _queues[l.kind]!;
    if (!q.remove(l)) return;
    _renumber(l.kind);
  }

  void _renumber(ResourceKind kind) {
    final q = _queues[kind]!;
    for (var i = 0; i < q.length; i++) {
      final s = q[i].state;
      if (s is Queued && s.position != i + 1) _to(q[i], Queued(i + 1, s.since));
    }
  }

  void _grantFree(ResourceKind kind) {
    final q = _queues[kind]!;
    final now = _now();
    var moved = false;
    while (q.isNotEmpty && holders(kind).length < capacity(kind)) {
      final head = q.removeAt(0);
      _to(head, Granted(now));
      moved = true;
    }
    if (moved) _renumber(kind);
  }

  /// Queued tickets with no call for [ticketKeep] lose their place (not the user's: the Preview waits shown).
  void _expire(ResourceKind kind) {
    final now = _now();
    final q = _queues[kind]!;
    final gone = [
      for (final l in q)
        if (!l.isUser && now.difference(l._lastCall) >= ticketKeep) l,
    ];
    if (gone.isEmpty) return;
    for (final l in gone) {
      _to(l, const Released());
      q.remove(l);
      _leases.remove(l.id);
    }
    _renumber(kind);
    _grantFree(kind);
    notifyListeners();
  }

  void _markIdle(ResourceKind kind, DateTime now) {
    for (final l in holders(kind)) {
      final last = switch (l.state) {
        Granted(:final at) => at,
        Active(:final lastUsed) => lastUsed,
        _ => null,
      };
      if (last != null && now.difference(last) >= idleAfter) _to(l, Idle(last));
    }
  }
}

/// The text a call gets while its ticket waits: its place, who holds the slots, and that the place is kept.
String queuedText(Pool pool, Lease lease, {String Function(String holder)? nameOf}) {
  final n = pool.queued(lease.kind).length;
  final k = pool.position(lease) ?? n;
  final names = [for (final h in pool.holders(lease.kind)) (nameOf ?? holderName)(h.holder)];
  final a = lease.kind == ResourceKind.emulator ? 'an' : 'a';
  return 'Queued for $a ${lease.kind.label}: position $k of $n; held by ${names.isEmpty ? 'nobody yet' : names.join(', ')}. '
      'Do other work and call again; your place is kept for ${pool.ticketKeep.inMinutes} minutes.';
}

/// A holder's id without its prefix ("agent:abc" → "abc"), and the user's Preview named as such.
String holderName(String holder) {
  if (holder.startsWith('user:')) return 'your Preview (${holder.substring(5)})';
  final i = holder.indexOf(':');
  return i < 0 ? holder : holder.substring(i + 1);
}

/// 1 → "1st", 2 → "2nd", 11 → "11th".
String ordinal(int n) {
  final teen = n % 100 >= 11 && n % 100 <= 13;
  final suffix = teen ? 'th' : const {1: 'st', 2: 'nd', 3: 'rd'}[n % 10] ?? 'th';
  return '$n$suffix';
}
