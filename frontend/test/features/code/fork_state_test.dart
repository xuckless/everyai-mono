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
  });
}
