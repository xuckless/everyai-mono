// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:every_ai/core/process/pool.dart';
import 'package:every_ai/features/code/live/live_pool.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  var now = DateTime(2026, 11, 12, 9);
  Pool pool0() => Pool(capacity: {ResourceKind.browser: 1}, clock: () => now);

  setUp(() => now = DateTime(2026, 11, 12, 9));

  test('FIFO queue, handover on release, one ticket per holder', () {
    final pool = pool0();
    final a = pool.acquire('agent:a', ResourceKind.browser);
    final b = pool.acquire('agent:b', ResourceKind.browser);
    final c = pool.acquire('agent:c', ResourceKind.browser);
    expect(a.state, isA<Granted>());
    expect([pool.position(b), pool.position(c)], [1, 2]);
    expect(pool.acquire('agent:b', ResourceKind.browser), same(b));
    pool.release(a);
    expect(a.state, isA<Released>());
    expect(b.state, isA<Granted>());
    expect(pool.position(c), 1);
    expect(pool.holders(ResourceKind.browser), [b]);
    expect(pool.refused, isEmpty);
  });

  test('an idle holder is nudged, never evicted; the user is never nudged', () {
    final pool = pool0();
    final a = pool.acquire('agent:a', ResourceKind.browser);
    pool.touch(a);
    expect(pool.nudgeFor(a), isNull);
    pool.acquire('agent:b', ResourceKind.browser);
    now = now.add(const Duration(minutes: 3));
    expect(
      pool.nudgeFor(a),
      "It seems you haven't used the browser for 3 min; 1 agent is behind you in the queue. "
      'Close it (action close) if you are done.',
    );
    expect(a.state, isA<Idle>());
    expect(pool.holders(ResourceKind.browser), [a]);
    pool.touch(a);
    expect(a.state, isA<Active>());

    final user = Pool(capacity: {ResourceKind.browser: 1}, clock: () => now);
    final u = user.acquire('user:s', ResourceKind.browser);
    user.acquire('agent:x', ResourceKind.browser);
    now = now.add(const Duration(minutes: 10));
    expect(user.nudgeFor(u), isNull);
    expect(u.state.holdsSlot, isTrue);
  });

  test('a queued ticket is kept for 2 minutes between calls', () {
    final pool = pool0();
    pool.acquire('agent:a', ResourceKind.browser);
    final b = pool.acquire('agent:b', ResourceKind.browser);
    now = now.add(const Duration(seconds: 90));
    expect(pool.acquire('agent:b', ResourceKind.browser), same(b));
    now = now.add(const Duration(seconds: 119));
    expect(pool.leaseOf('agent:b', ResourceKind.browser), same(b));
    now = now.add(const Duration(seconds: 2));
    expect(pool.leaseOf('agent:b', ResourceKind.browser), isNull);
    expect(b.state, isA<Released>());
  });

  test('transition table', () {
    final t = DateTime(2026);
    expect(leaseEdge(Queued(1, t), Granted(t)), isTrue);
    expect(leaseEdge(Granted(t), Active(t)), isTrue);
    expect(leaseEdge(Active(t), Idle(t)), isTrue);
    expect(leaseEdge(Idle(t), Active(t)), isTrue);
    expect(leaseEdge(Active(t), const Releasing()), isTrue);
    expect(leaseEdge(const Releasing(), const Released()), isTrue);
    expect(leaseEdge(Queued(1, t), Active(t)), isFalse);
    expect(leaseEdge(const Released(), Granted(t)), isFalse);
    expect(leaseEdge(const Failed('x'), const Released()), isFalse);
    expect(leaseEdge(Idle(t), Granted(t)), isFalse);
  });

  test('auto capacity', () {
    expect(autoCapacity(ramGb: 16, cores: 8), {
      ResourceKind.browser: 6,
      ResourceKind.simulator: 1,
      ResourceKind.emulator: 1,
      ResourceKind.stream: 4,
      ResourceKind.display: 6,
      ResourceKind.session: 8,
    });
    expect(autoCapacity(ramGb: 64, cores: 12)[ResourceKind.browser], 8);
    expect(autoCapacity(ramGb: 64, cores: 12)[ResourceKind.emulator], 2);
    expect(autoCapacity(ramGb: 4, cores: 2)[ResourceKind.browser], 2);
    expect(autoCapacity(ramGb: 4, cores: 2)[ResourceKind.session], 4);
  });

  test('an agent call gets the queued text when no slot frees in time', () async {
    LivePool.pool = Pool(capacity: {ResourceKind.browser: 1});
    LivePool.nameOf = null;
    final first = await LivePool.forAgent('s1', ResourceKind.browser, wait: Duration.zero);
    expect(first, isA<TurnGranted>());
    final second = await LivePool.forAgent('s2', ResourceKind.browser, wait: const Duration(milliseconds: 20));
    expect(
      (second as TurnQueued).text,
      'Queued for a browser: position 1 of 1; held by s1. Do other work and call again; your place is kept for 2 '
      'minutes.',
    );
    // The holder closes: the queued agent's next call gets its turn.
    await LivePool.releaseAround('s1', ResourceKind.browser, () async {});
    expect(await LivePool.forAgent('s2', ResourceKind.browser, wait: Duration.zero), isA<TurnGranted>());
  });
}
