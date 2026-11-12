// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/preferences.dart';
import '../../../core/process/pool.dart';
import 'live_pool_machine_stub.dart' if (dart.library.io) 'live_pool_machine_io.dart';

/// What a call on a pooled resource gets: its turn (with a nudge when it sat idle while others wait), or its place
/// in the queue as the text the tool call returns.
@immutable
sealed class PoolTurn {
  const PoolTurn();
}

final class TurnGranted extends PoolTurn {
  const TurnGranted(this.lease, {this.nudge});
  final Lease lease;

  /// [Pool.nudgeFor]'s line, appended to the call's result.
  final String? nudge;
}

final class TurnQueued extends PoolTurn {
  const TurnQueued(this.lease, this.text);
  final Lease lease;

  /// [queuedText]: the tool result.
  final String text;
}

/// The app's one live-resource pool and the rules for whose lease a session's resource is. A session's resource has
/// one lease, whoever took it first: the agent (`agent:<session>`) or the user's Preview (`user:<session>`); both
/// use it while it holds the slot.
abstract final class LivePool {
  static Pool pool = Pool();

  /// A holder's name in "held by …" (the session's title); set at app start.
  static String Function(String holder)? nameOf;

  /// How long the EveryAI harness's call waits for its turn before it returns the queued text.
  static Duration agentWait = const Duration(seconds: 20);

  static String agentHolder(String session) => 'agent:$session';
  static String userHolder(String session) => 'user:$session';

  /// Session [session]'s live lease of [kind] (the agent's or the Preview's), or null.
  static Lease? sessionLease(String session, ResourceKind kind) =>
      pool.leaseOf(agentHolder(session), kind) ?? pool.leaseOf(userHolder(session), kind);

  /// The agent of [session] asks for its [kind]: its turn at once when the session holds one (touched; with a nudge
  /// when it sat idle while others queue), else it waits up to [wait] for a slot (zero for an outside lead: the
  /// queued text at once). A queued ticket keeps its place for [Pool.ticketKeep] between calls.
  static Future<PoolTurn> forAgent(String session, ResourceKind kind, {Duration? wait}) async {
    final lease = sessionLease(session, kind) ?? pool.acquire(agentHolder(session), kind);
    if (lease.state.holdsSlot) {
      final nudge = pool.nudgeFor(lease);
      pool.touch(lease);
      return TurnGranted(lease, nudge: nudge);
    }
    pool.touch(lease);
    if (await pool.waitGranted(lease, wait ?? agentWait)) {
      pool.touch(lease);
      return TurnGranted(lease);
    }
    return TurnQueued(lease, queuedText(pool, lease, nameOf: nameOf));
  }

  /// The nudge for [session]'s agent when it holds a resource idle while others queue (any kind), or null.
  static String? nudgeForSession(String session) {
    for (final kind in ResourceKind.values) {
      if (pool.leaseOf(agentHolder(session), kind) case final l?) {
        if (pool.nudgeFor(l) case final n?) return n;
      }
    }
    return null;
  }

  /// The user's Preview of [session] shows its [kind]: the session's lease when it has one, else the user's own
  /// (queued like anyone's when the pool is full; the Preview shows its place).
  static Lease forUser(String session, ResourceKind kind) {
    final lease = sessionLease(session, kind) ?? pool.acquire(userHolder(session), kind);
    pool.touch(lease);
    return lease;
  }

  /// Ends [session]'s lease of [kind] around [close] (the resource's own close). A close that throws fails the
  /// lease loudly (logged and rethrown); the slot is passed on either way.
  static Future<void> releaseAround(String session, ResourceKind kind, Future<void> Function() close) async {
    final lease = sessionLease(session, kind);
    if (lease == null) return close();
    pool.beginRelease(lease);
    try {
      await close();
    } catch (e) {
      debugPrint('NOT CLOSED: ${kind.label} of session $session: $e');
      pool.finishRelease(lease, failure: '$e');
      rethrow;
    }
    pool.finishRelease(lease);
  }

  /// Ends every lease (any kind) of [session] whose resource is already gone or going (the session was removed).
  static void releaseSession(String session) {
    for (final kind in ResourceKind.values) {
      for (final h in [agentHolder(session), userHolder(session), 'session:$session']) {
        if (pool.leaseOf(h, kind) case final l?) pool.release(l);
      }
    }
  }

  /// Sets the capacities: this machine's auto numbers, then the user's (Preferences `code.pool.<kind>`).
  static Future<void> configure(String? Function(String key) pref) async {
    final machine = await readMachine();
    final auto = machine == null ? fallbackCapacity : autoCapacity(ramGb: machine.ramGb, cores: machine.cores);
    for (final kind in ResourceKind.values) {
      pool.setCapacity(kind, int.tryParse(pref(kind.prefKey) ?? '') ?? auto[kind]!);
    }
  }
}

/// The live pool for the UI (Settings numbers, Processes, queue chips): a Listenable (wrap reads in a
/// ListenableBuilder; the pool outlives the provider, so it isn't disposed with it); its
/// `capacities`, `holders(kind)`, `queued(kind)` and `position(lease)` say who has what.
final livePoolProvider = Provider<Pool>((ref) {
  final prefs = ref.watch(preferencesProvider);
  unawaited(LivePool.configure((k) => prefs[k]));
  return LivePool.pool;
});
