import 'dart:convert';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/features/code/board/board_providers.dart';
import 'package:every_ai/features/code/board/board_state.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/drivers/driver_events.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

CodeSessionInfo _s(String id, {String? parent}) => CodeSessionInfo(
  id: id,
  projectId: 'p1',
  title: 'Session $id',
  conversationId: 'c-$id',
  model: 'a/m',
  mode: AgentMode.ask,
  workingDir: 'demo://p1',
  createdAt: DateTime(2026, 11, 1),
  parentId: parent,
);

/// A transcript of [commands] run one after another, each finished.
void main() {
  group('the card phase', () {
    const forks = (forks: 2, subagents: 0, workflows: 0);

    test('anything waiting on the user wins; a failure shows even with work out', () {
      expect(boardPhase(SessionStatus.needsInput), BoardPhase.needsYou);
      expect(boardPhase(SessionStatus.running, childWaits: true), BoardPhase.needsYou);
      expect(boardPhase(SessionStatus.failed, work: forks), BoardPhase.failed);
    });

    test('a finish is unseen until the user opens it', () {
      expect(boardPhase(SessionStatus.done), BoardPhase.doneUnseen);
      expect(boardPhase(SessionStatus.idle, seen: true), BoardPhase.doneSeen);
      expect(
        [for (final p in BoardPhase.values) p.column.name],
        ['needsYou', 'running', 'running', 'running', 'done', 'done', 'done'],
      );
    });
  });

  test('running forks and subagents are counted at every depth, once each', () {
    final all = [_s('lead'), _s('f1', parent: 'lead'), _s('f2', parent: 'lead'), _s('g', parent: 'f1')];
    final running = {'f2', 'g'};
    int count(String id) => runningDescendants(
      id,
      childrenByParent(all),
      (s) => running.contains(s.id) ? SessionStatus.running : SessionStatus.done,
    );
    expect(count('lead'), 2);
    expect(count('f1'), 1);
    expect(count('f2'), 0);
  });

  group('same step in a row follows the loop guard', () {
    ActionCall tool(String id, String name, {String kind = 'TerminalAction', Map<String, Object?>? args}) =>
        actionEvent(id: id, toolName: name, kind: kind, args: args ?? const {'command': 'x'});

    Transcript of(List<Object> events) {
      final b = TranscriptBuilder();
      for (final e in events) {
        switch (e) {
          case final ActionCall c:
            b
              ..add(c)
              ..add(resultEvent(id: 'r-${c.id}', actionId: c.id, toolName: c.toolName, text: 'ok'));
          case final HarnessEvent h:
            b.add(h);
        }
      }
      return b.snapshot;
    }

    test('calls the guard ignores (client tools, thinking, trackers) are not a loop', () {
      final checks = [for (var i = 0; i < 3; i++) tool('f$i', 'check_forks', kind: '', args: const {})];
      expect(repeatedStep(of(checks)), isNull);
      final think = [
        for (var i = 0; i < 3; i++) tool('t$i', 'think', kind: 'ThinkAction', args: const {'thought': 'x'}),
      ];
      expect(repeatedStep(of(think)), isNull);
      // They don't break a real run either.
      expect(
        repeatedStep(
          of([
            tool('a', 'bash'),
            tool('c', 'check_forks', kind: '', args: const {}),
            tool('b', 'bash'),
            tool('d', 'bash'),
          ]),
        ),
        isNotNull,
      );
    });
  });

  group('warnings', () {
    test('stalled and looping only while the lead works; a full context while anything runs', () {
      final w = boardWarnings(
        phase: BoardPhase.working,
        sinceProgress: const Duration(minutes: 7),
        repeated: 'flutter test',
        contextPercent: 93,
      );
      expect([for (final x in w) x.line], ['No progress for 7 min', 'Same step 3×: flutter test', 'Context 93%']);
      expect(boardWarnings(phase: BoardPhase.working, sinceProgress: const Duration(minutes: 5)), isEmpty);
      expect(
        boardWarnings(phase: BoardPhase.waitingOnWork, sinceProgress: const Duration(hours: 1), repeated: 'x'),
        isEmpty,
      );
      expect([for (final x in boardWarnings(phase: BoardPhase.needsYou, contextPercent: 90)) x.line], ['Context 90%']);
      expect(boardWarnings(phase: BoardPhase.doneUnseen, contextPercent: 99), isEmpty);
    });
  });

  group('seen', () {
    late AppDatabase db;
    late Preferences prefs;
    late ProviderContainer c;
    final t0 = DateTime(2026, 11, 11, 10);

    ProviderContainer make() => ProviderContainer(overrides: [preferencesProvider.overrideWithValue(prefs)]);

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      prefs = await Preferences.load(db);
      prefs[BoardMarks.doneSinceKey] = '{}';
      c = make();
    });
    tearDown(() async {
      c.dispose();
      await db.close();
    });

    test('one transition function moves a session between the states', () {
      SeenState go(SeenState s, SeenEvent e) => seenTransition(s, e);
      const none = NotTracked();
      final unseen = go(none, Finished(t0));
      expect(unseen, FinishedUnseen(t0));
      // A later sighting of the same finish changes nothing.
      expect(go(unseen, Finished(t0.add(const Duration(hours: 1)))), unseen);
      final seen = go(unseen, Looked(t0.add(const Duration(minutes: 5))));
      expect(seen, FinishedSeen(t0, t0.add(const Duration(minutes: 5))));
      expect(go(seen, Looked(t0.add(const Duration(hours: 1)))), seen);
      // Running drops the marks; the next finish is news again.
      expect(go(seen, const Ran()), const RunningAgain());
      expect(go(unseen, const Ran()), const RunningAgain());
      expect(go(go(seen, const Ran()), Finished(t0)), FinishedUnseen(t0));
      // Looking at a finish the Board hasn't recorded records it as seen; running with nothing recorded is nothing.
      expect(go(none, Looked(t0)), FinishedSeen(t0, t0));
      expect(go(none, const Ran()), none);
    });

    test('the marks have one writer: it writes only when a state changes, in the old preference format', () {
      final n = c.read(boardMarksProvider.notifier);
      n.apply('a', Looked(t0));
      expect(c.read(boardMarksProvider).of('a'), FinishedSeen(t0, t0));
      expect(jsonDecode(prefs[BoardMarks.doneSinceKey]!), {'a': t0.millisecondsSinceEpoch});
      expect(jsonDecode(prefs[BoardMarks.seenKey]!), {'a': t0.millisecondsSinceEpoch});
      // The session view calls this on every build: no change, no write.
      prefs[BoardMarks.seenKey] = 'untouched';
      n.apply('a', Looked(t0.add(const Duration(minutes: 1))));
      n.apply('zz', const Ran());
      expect(prefs[BoardMarks.seenKey], 'untouched');
      n.apply('a', const Ran());
      expect(c.read(boardMarksProvider).of('a'), const NotTracked());
      expect(jsonDecode(prefs[BoardMarks.doneSinceKey]!), isEmpty);
    });

    test('old preferences load: a look at or after the finish is seen, an earlier one is not', () {
      prefs[BoardMarks.doneSinceKey] = jsonEncode({
        'a': t0.millisecondsSinceEpoch,
        'b': t0.millisecondsSinceEpoch,
        'c': t0.millisecondsSinceEpoch,
      });
      prefs[BoardMarks.seenKey] = jsonEncode({
        'a': t0.millisecondsSinceEpoch,
        'b': t0.millisecondsSinceEpoch - 1,
        'stray': t0.millisecondsSinceEpoch,
      });
      final set = make().read(boardMarksProvider);
      expect(set.era, MarksEra.tracking);
      expect(set.of('a'), FinishedSeen(t0, t0));
      expect(set.of('b'), FinishedUnseen(t0));
      expect(set.of('c'), FinishedUnseen(t0));
      expect(set.of('stray'), const NotTracked());
    });
  });
}
