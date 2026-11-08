import 'package:every_ai/features/code/domain/fork_state.dart';
import 'package:every_ai/features/code/domain/subagents.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const ask = AskToLead('q1');
  const working = <ForkState>[
    ForkRunning(),
    ForkRunning(followUp: true),
    ForkWaitingOnLead(ask),
    ForkWaitingOnUser(),
    ForkPausing(),
    ForkPaused(),
  ];
  const reported = ForkReported(SubagentStatus.completed);
  const dropped = ForkDropped('x');

  test('the diagram: every edge it draws is allowed, and nothing else', () {
    final allowed = <(ForkState, ForkState)>[
      (const ForkSpawning(), const ForkRunning()),
      (const ForkSpawning(), dropped),
      (const ForkSpawning(), const ForkStopping()),
      for (final from in working) ...[
        (from, const ForkSpawning()),
        (from, const ForkStopping()),
        (from, const ForkMerging()),
        (from, reported),
        (from, dropped),
        (from, const ForkRunning()),
        (from, const ForkWaitingOnLead(ask)),
        (from, const ForkWaitingOnUser()),
        (from, const ForkPausing()),
      ],
      (const ForkPausing(), const ForkPaused()),
      (const ForkStopping(), const ForkMerging()),
      (const ForkStopping(), reported),
      (const ForkStopping(), dropped),
      (const ForkMerging(), reported),
      (const ForkMerging(), dropped),
      (reported, const ForkRunning(followUp: true)),
    ];
    for (final (from, to) in allowed) {
      expect(forkEdge(from, to), isTrue, reason: '$from → $to');
    }
    final refused = <(ForkState, ForkState)>[
      // Paused only through pausing.
      (const ForkRunning(), const ForkPaused()),
      (const ForkWaitingOnUser(), const ForkPaused()),
      (const ForkPaused(), const ForkPaused()),
      // A starting fork has nothing to pause, ask or report yet.
      (const ForkSpawning(), const ForkPausing()),
      (const ForkSpawning(), const ForkWaitingOnLead(ask)),
      (const ForkSpawning(), reported),
      (const ForkSpawning(), const ForkRunning(followUp: true)),
      // Stopping and merging only go on to the end.
      (const ForkStopping(), const ForkRunning()),
      (const ForkMerging(), const ForkRunning()),
      (const ForkMerging(), const ForkStopping()),
      // A report happens once; working again is a follow-up, and the ends stay ends.
      (reported, reported),
      (reported, const ForkRunning()),
      (reported, const ForkMerging()),
      (reported, dropped),
      (dropped, const ForkRunning()),
      (dropped, const ForkRunning(followUp: true)),
      (dropped, reported),
    ];
    for (final (from, to) in refused) {
      expect(forkEdge(from, to), isFalse, reason: '$from → $to');
    }
  });

  test('live and working', () {
    for (final s in working) {
      expect(s.live && s.working, isTrue, reason: '$s');
    }
    for (final s in [const ForkSpawning(), const ForkStopping(), const ForkMerging()]) {
      expect(s.live && !s.working, isTrue, reason: '$s');
    }
    expect(reported.live || dropped.live, isFalse);
  });

  group('ForkBook', () {
    test('a background fork: spawn, start, report once, then a follow-up', () {
      final b = ForkBook();
      final r = b.spawn('c1', title: 'Add the page');
      expect(b.spawning.single, r);
      expect(b.children, isEmpty);
      b.started('c1', 'kid1', title: 'Add the settings page');
      expect(r.state, const ForkRunning());
      expect(b.children, {'c1': 'kid1'});
      expect(b.background.single.title, 'Add the settings page');
      expect(b.byChild('kid1'), r);
      expect(b.to('c1', const ForkMerging()), isTrue);
      expect(b.to('c1', reported), isTrue);
      expect(r.reports, 1);
      expect(b.live, isEmpty);
      expect(b.reported.single.reportedAs, SubagentStatus.completed);
      // It works again: a follow-up, and its next report counts.
      expect(b.to('c1', const ForkRunning(followUp: true)), isTrue);
      expect(b.live.single, r);
      expect(b.to('c1', const ForkReported(SubagentStatus.failed)), isTrue);
      expect(r.reports, 2);
      expect(b.refused, isEmpty);
    });

    test('a refused move is recorded and the state stays', () {
      final b = ForkBook()..spawn('c1', title: 't');
      expect(() => b.to('c1', reported), throwsA(isA<AssertionError>()));
      expect(b.of('c1')!.state, const ForkSpawning());
      expect(b.refused.single, 'c1: spawning → reported(completed)');
      expect(b.to('nope', const ForkRunning()), isFalse);
    });

    test('the same state again is no move; another question is', () {
      final b = ForkBook()
        ..spawn('c1', title: 't')
        ..started('c1', 'k');
      expect(b.to('c1', const ForkRunning()), isTrue);
      expect(b.askLead('c1', 'q1'), isTrue);
      expect(b.askLead('c1', 'q1'), isFalse, reason: 'already went');
      expect(b.askLead('c1', 'q2'), isTrue);
      expect((b.of('c1')!.state as ForkWaitingOnLead).ask.questionId, 'q2');
      expect(b.refused, isEmpty);
    });

    test('question routes: to the lead, then answered by the lead or by the user first', () {
      final b = ForkBook()
        ..spawn('c1', title: 't')
        ..started('c1', 'k')
        ..askLead('c1', 'q1')
        ..askLead('c1', 'q2');
      expect(b.askedLead('q1'), isTrue);
      expect(b.askedLead('q9'), isFalse);
      expect(b.answered('q1', byUser: false), isTrue);
      expect(b.of('c1')!.askOf('q1'), isA<AskAnsweredByLead>());
      // Answered once: a late answer from the other side doesn't count.
      expect(b.answered('q1', byUser: true), isFalse);
      expect(b.answered('q2', byUser: true), isTrue);
      expect(b.of('c1')!.askOf('q2'), isA<AskAnsweredByUser>());
      expect(b.answered('q9', byUser: true), isFalse);
      // Answered questions still count as having gone to the lead (the Board's "asked the lead").
      expect(b.askedLead('q2'), isTrue);
    });

    test('waiting on the user, a retry back to spawning, and Stop all', () {
      final b = ForkBook()
        ..spawn('c1', title: 'a')
        ..started('c1', 'k1')
        ..spawn('c2', title: 'b')
        ..spawn('c3', title: 'c', delivery: ForkDelivery.call);
      b.to('c1', const ForkWaitingOnUser());
      expect(b.anyWaitingOnUser, isTrue);
      // A retry on the lead's model keeps the record.
      final again = b.spawn('c1', title: 'a');
      expect(again, b.of('c1'));
      expect(again.state, const ForkSpawning());
      expect(again.childId, 'k1');
      expect(b.anyWaitingOnUser, isFalse);
      b.started('c1', 'k2');
      expect(b.children['c1'], 'k2');
      expect(b.background.map((r) => r.callId), ['c1', 'c2']);
      expect(b.dropLive('Stopped.'), ['k2']);
      expect(b.live, isEmpty);
      expect(b.all.every((r) => r.state is ForkDropped), isTrue);
      expect(b.refused, isEmpty);
    });
  });
}
