import 'dart:convert';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/features/code/board/board_providers.dart';
import 'package:every_ai/features/code/board/board_state.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/subagents.dart' show taskTool;
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
Transcript _ran(List<String> commands) {
  final b = TranscriptBuilder();
  for (final (i, c) in commands.indexed) {
    b
      ..add(actionEvent(id: 'c$i', toolName: 'bash', kind: 'TerminalAction', args: {'command': c}))
      ..add(resultEvent(id: 'r$i', actionId: 'c$i', toolName: 'bash', text: 'ok'));
  }
  return b.snapshot;
}

void main() {
  group('the card phase', () {
    const forks = (forks: 2, subagents: 0, workflows: 0);

    test('the lead running is Working; idle with work out is Waiting on its own work', () {
      expect(boardPhase(SessionStatus.running), BoardPhase.working);
      expect(boardPhase(SessionStatus.starting), BoardPhase.working);
      expect(boardPhase(SessionStatus.idle, work: forks), BoardPhase.waitingOnWork);
      expect(boardPhase(SessionStatus.done, work: (forks: 0, subagents: 1, workflows: 0)), BoardPhase.waitingOnWork);
      expect(boardPhase(SessionStatus.done, work: (forks: 0, subagents: 0, workflows: 1)), BoardPhase.waitingOnWork);
    });

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

    test('a paused session is Paused, in Running, without glow; work out does not make it Working', () {
      expect(boardPhase(SessionStatus.paused), BoardPhase.paused);
      expect(boardPhase(SessionStatus.paused, work: forks), BoardPhase.paused);
      expect(BoardPhase.paused.active, isFalse);
      expect(boardPhaseLine(BoardPhase.paused, forks), 'Paused');
    });

    test('opening a session changes its seen mark only once it has connected and says how it stands', () {
      SeenUpdate u(SessionStatus st, {bool connected = true, bool work = false}) =>
          seenUpdate(status: st, connected: connected, sideWork: work);
      // Still connecting, or starting: its status says nothing about the last finish yet.
      expect(u(SessionStatus.done, connected: false), SeenUpdate.none);
      expect(u(SessionStatus.running, connected: false), SeenUpdate.none);
      expect(u(SessionStatus.starting), SeenUpdate.none);
      expect(u(SessionStatus.done), SeenUpdate.finished);
      expect(u(SessionStatus.idle, work: true), SeenUpdate.running);
      expect(u(SessionStatus.paused), SeenUpdate.running);
      expect(u(SessionStatus.needsInput), SeenUpdate.running);
    });

    test('the status line names the work in flight', () {
      expect(
        boardPhaseLine(BoardPhase.waitingOnWork, (forks: 3, subagents: 0, workflows: 0)),
        'Lead waiting · 3 forks running',
      );
      expect(
        boardPhaseLine(BoardPhase.working, (forks: 1, subagents: 1, workflows: 2)),
        'Lead working · 1 fork running · 1 subagent running · 2 workflows running',
      );
      expect(boardPhaseLine(BoardPhase.working, noBoardWork), '');
      expect(boardPhaseLine(BoardPhase.doneUnseen, forks), '');
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

  test('a fork starting, paused or waiting is still work for its idle lead; a finished one is not', () {
    final all = [_s('lead'), _s('a', parent: 'lead'), _s('b', parent: 'lead'), _s('c', parent: 'lead')];
    for (final st in [SessionStatus.starting, SessionStatus.paused, SessionStatus.needsInput, SessionStatus.running]) {
      final n = runningDescendants('lead', childrenByParent(all), (s) => s.id == 'a' ? st : SessionStatus.done);
      expect(n, 1, reason: '$st');
      final work = (forks: n, subagents: 0, workflows: 0);
      expect(boardPhase(SessionStatus.idle, work: work), BoardPhase.waitingOnWork, reason: '$st');
    }
    for (final st in [SessionStatus.idle, SessionStatus.done, SessionStatus.failed]) {
      expect(runningDescendants('lead', childrenByParent(all), (_) => st), 0, reason: '$st');
    }
  });

  test("a closed fork's polled wait is not work for its lead; an open one's is", () {
    final all = [_s('lead'), _s('a', parent: 'lead'), _s('g', parent: 'a')];
    final byParent = childrenByParent(all);
    SessionStatus waits(CodeSessionInfo s) => s.id == 'g' ? SessionStatus.needsInput : SessionStatus.done;
    expect(runningDescendants('lead', byParent, waits, isOpen: (_) => false), 0);
    expect(runningDescendants('lead', byParent, waits, isOpen: (s) => s.id == 'g'), 1);
    // The Board opens the closed ones that wait, at any depth.
    expect([for (final s in closedWaiting('lead', byParent, waits, (_) => false)) s.id], ['g']);
    expect(closedWaiting('lead', byParent, waits, (s) => s.id == 'g'), isEmpty);
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

    test('the user speaking starts the count again', () {
      final user = ChatMessage(id: 'u1', raw: const {}, fromUser: true, text: 'try again');
      expect(repeatedStep(of([tool('a', 'bash'), tool('b', 'bash'), user, tool('c', 'bash')])), isNull);
      expect(
        repeatedStep(of([tool('a', 'bash'), user, tool('b', 'bash'), tool('c', 'bash'), tool('d', 'bash')])),
        isNotNull,
      );
    });
  });

  test("an outside lead's subagents still out are listed with their task; ours and finished ones aren't", () {
    SubagentItem agent(String tool, String id, {bool done = false}) {
      final call = actionEvent(id: id, toolName: tool, kind: 'TaskAction', args: const {'description': 'Map the API'});
      return SubagentItem(
        ToolStep(call, done ? resultEvent(id: 'r-$id', actionId: id, toolName: tool, text: '') : null),
      );
    }

    final t = Transcript(items: [agent('Agent', 'a1'), agent('Agent', 'a2', done: true), agent(taskTool, 'a3')]);
    expect(outsideSubagents(t), [(id: 'a1', task: 'Map the API')]);
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

    test('no stall or loop warning for a paused session, nor a stall before it has connected', () {
      expect(
        boardWarnings(phase: BoardPhase.paused, sinceProgress: const Duration(hours: 1), repeated: 'npm test'),
        isEmpty,
      );
      expect(
        boardWarnings(phase: BoardPhase.working, sinceProgress: const Duration(hours: 1), connected: false),
        isEmpty,
      );
    });

    test('the same command three times in a row is a loop; a different one in between is not', () {
      expect(repeatedStep(_ran(['npm test', 'npm test', 'npm  test'])), contains('npm test'));
      expect(repeatedStep(_ran(['npm test', 'ls', 'npm test'])), isNull);
      expect(repeatedStep(_ran(['npm test', 'npm test'])), isNull);
    });

    test('context percent needs both numbers', () {
      expect(contextPercent(180000, 200000), 90);
      expect(contextPercent(180000, 0), 0);
      expect(contextPercent(0, 200000), 0);
      expect(contextPercent(400000, 200000), 100);
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

    test('before the Board first records, finishes count from creation and the first refresh starts tracking', () {
      final fresh = AppDatabase(NativeDatabase.memory());
      addTearDown(fresh.close);
      return Preferences.load(fresh).then((p) {
        final k = ProviderContainer(overrides: [preferencesProvider.overrideWithValue(p)]);
        addTearDown(k.dispose);
        final set = k.read(boardMarksProvider);
        expect(set.era, MarksEra.firstRun);
        expect(set.finishedAt(DateTime(2026, 11, 1), t0), DateTime(2026, 11, 1));
        // A look before the first record writes only what was seen.
        k.read(boardMarksProvider.notifier).apply('a', Looked(t0));
        expect(p[BoardMarks.doneSinceKey], isNull);
        expect(k.read(boardMarksProvider).era, MarksEra.firstRun);
        k.read(boardMarksProvider.notifier).sync(finished: {'b': FinishedUnseen(DateTime(2026, 11, 1))});
        expect(k.read(boardMarksProvider).era, MarksEra.tracking);
        expect(k.read(boardMarksProvider).finishedAt(DateTime(2026, 11, 1), t0), t0);
        expect(
          jsonDecode(p[BoardMarks.doneSinceKey]!),
          containsPair('b', DateTime(2026, 11, 1).millisecondsSinceEpoch),
        );
      });
    });

    test('the Board refresh sets finished sessions, drops those that ran again or are gone, once', () {
      final n = c.read(boardMarksProvider.notifier);
      n.sync(finished: {'a': FinishedUnseen(t0), 'b': FinishedSeen(t0, t0), 'c': FinishedUnseen(t0)});
      n.sync(finished: {'a': FinishedUnseen(t0)}, ran: ['b'], gone: ['c']);
      expect(c.read(boardMarksProvider).marks, {'a': FinishedUnseen(t0)});
      prefs[BoardMarks.doneSinceKey] = 'untouched';
      n.sync(finished: {'a': FinishedUnseen(t0)});
      expect(prefs[BoardMarks.doneSinceKey], 'untouched');
    });
  });
}
