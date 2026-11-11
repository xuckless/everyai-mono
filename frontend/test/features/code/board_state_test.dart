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
    late ProviderContainer c;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      final prefs = await Preferences.load(db);
      prefs[BoardDoneSince.key] = '{}';
      c = ProviderContainer(overrides: [preferencesProvider.overrideWithValue(prefs)]);
    });
    tearDown(() async {
      c.dispose();
      await db.close();
    });

    test('a mark at or after the finish counts; running again drops it', () {
      final done = DateTime(2026, 11, 11, 10);
      expect(seenSince(done.millisecondsSinceEpoch, done), isTrue);
      expect(seenSince(done.millisecondsSinceEpoch - 1, done), isFalse);
      expect(seenSince(null, done), isFalse);

      c.read(boardSeenProvider.notifier).see('a', at: done);
      expect(c.read(boardSeenProvider), {'a': done.millisecondsSinceEpoch});
      c.read(boardSeenProvider.notifier).forget(['a']);
      expect(c.read(boardSeenProvider), isEmpty);
    });

    test('the finish time is recorded once, and forgotten when the session runs again', () {
      final n = c.read(boardDoneSinceProvider.notifier);
      n.mark('a', DateTime(2026, 11, 11, 10));
      n.mark('a', DateTime(2026, 11, 11, 12));
      expect(c.read(boardDoneSinceProvider), {'a': DateTime(2026, 11, 11, 10).millisecondsSinceEpoch});
      n.forget('a');
      expect(c.read(boardDoneSinceProvider), isEmpty);
    });
  });
}
