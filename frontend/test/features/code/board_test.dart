import 'dart:convert';

import 'package:drift/native.dart';
import 'package:every_ai/app/shell.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/features/code/board/board_providers.dart';
import 'package:every_ai/features/code/board/board_screen.dart';
import 'package:every_ai/features/code/board/board_state.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/drivers/driver_events.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/workflows/workflow_engine.dart';
import 'package:every_ai/features/code/workflows/workflow_runs.dart';
import 'package:every_ai/features/questions/domain/questions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../layout/layout_host.dart';

// The Board: columns by status, harness filters, detached forks, and the one-line activity on a card.

CodeSessionInfo _s(
  String id, {
  String harness = everyaiHarnessName,
  String? parent,
  int day = 1,
  String dir = 'demo://p1',
}) => CodeSessionInfo(
  id: id,
  projectId: 'p1',
  title: 'Session $id',
  conversationId: 'c-$id',
  model: 'a/m',
  mode: AgentMode.ask,
  // Demo sessions: the status poller leaves them alone.
  workingDir: dir,
  createdAt: DateTime(2026, 11, day),
  harness: harness,
  parentId: parent,
);

ActionCall _call(String id, Map<String, Object?> action) =>
    ActionCall(id: id, raw: const {}, toolName: 'tool', toolCallId: id, action: action);

void main() {
  test('columns follow the status', () {
    expect(BoardColumn.of(SessionStatus.needsInput), BoardColumn.needsYou);
    expect(BoardColumn.of(SessionStatus.starting), BoardColumn.running);
    expect(BoardColumn.of(SessionStatus.failed), BoardColumn.done);
    expect(BoardColumn.of(SessionStatus.idle), BoardColumn.done);
  });

  test("a session's running workflow and waiting children count on the Board", () {
    expect(boardStatus(SessionStatus.idle, workRunning: true, childWaits: false), SessionStatus.running);
    expect(boardStatus(SessionStatus.done, workRunning: false, childWaits: false), SessionStatus.done);
    expect(boardStatus(SessionStatus.idle, workRunning: true, childWaits: true), SessionStatus.needsInput);
    // A failure shows even while a workflow still runs.
    expect(boardStatus(SessionStatus.failed, workRunning: true, childWaits: false), SessionStatus.failed);
    expect(boardStatus(SessionStatus.running, workRunning: false, childWaits: true), SessionStatus.needsInput);
    expect(boardStatus(SessionStatus.starting, workRunning: true, childWaits: false), SessionStatus.starting);
  });

  test('Done clears by itself after two days, and keeps at most the newest eight', () {
    final now = DateTime(2026, 11, 11, 12);
    final since = {
      'old': now.subtract(const Duration(days: 3)),
      for (var i = 0; i < 9; i++) 'n$i': now.subtract(Duration(minutes: i)),
    };
    // The ninth newest goes over the cap; the three-day-old one is too old.
    expect(staleDone(since, now: now), {'old', 'n8'});
    expect(staleDone({'a': now}, now: now), isEmpty);
  });

  test('top-level sessions plus detached forks, newest first', () {
    final all = [_s('a', day: 1), _s('b', day: 3), _s('f', parent: 'a', day: 2), _s('g', parent: 'a', day: 4)];
    expect([for (final s in boardSessions(all, const {})) s.id], ['b', 'a']);
    expect(
      [
        for (final s in boardSessions(all, {'f'})) s.id,
      ],
      ['b', 'f', 'a'],
    );
    // Sessions of the removed harness can't be reopened, so they stay off.
    expect(boardSessions([_s('o', harness: openHandsHarnessName)], const {}), isEmpty);
  });

  test('activity: the approval it waits on, else the latest step or words', () {
    final edit = _call('1', {'kind': 'FileEditorAction', 'command': 'str_replace', 'path': 'lib/a.dart'});
    expect(boardActivity(Transcript(pending: [edit])), 'Edit lib/a.dart?');
    expect(
      boardActivity(
        Transcript(
          pending: [
            edit,
            _call('2', {'kind': 'TerminalAction', 'command': 'ls'}),
          ],
        ),
      ),
      'Edit lib/a.dart? (+1)',
    );
    expect(
      boardActivity(
        Transcript(
          items: [
            const UserTurn('u', 'go'),
            StepItem(ToolStep(_call('3', {'kind': 'TerminalAction', 'command': 'dart test'}))),
          ],
        ),
      ),
      'dart test',
    );
    expect(boardActivity(const Transcript(items: [AgentText('t', 'All done.\nDetails')])), 'All done.');
    expect(boardActivity(const Transcript()), '');
  });

  test('harness marks: known letters, a stable fallback', () {
    expect(harnessMark('claude-code').letters, 'CC');
    expect(harnessMark(everyaiHarnessName).letters, 'EA');
    expect(harnessMark('acp:kiro').letters, 'KI');
    expect(harnessMark('acp:kiro').color, harnessMark('acp:kiro').color);
  });

  testWidgets('cards land in their column; the harness filter narrows them', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    final db = AppDatabase(NativeDatabase.memory());
    final prefs = await Preferences.load(db);
    prefs['code.projects'] = '[{"id":"p1","name":"Alpha","path":"/tmp/p1"}]';
    // The Board has recorded finishes before: these count from now, not from when they started.
    prefs[BoardMarks.doneSinceKey] = '{}';
    prefs['code.sessions'] = jsonEncode([
      _s('a').toJson(),
      _s('b', harness: 'claude-code').toJson(),
      _s('c', harness: 'claude-code').toJson(),
      _s('f', parent: 'a').toJson(),
    ]);
    final c = ProviderContainer(overrides: [preferencesProvider.overrideWithValue(prefs)]);
    c.listen(codeStatusesProvider, (_, _) {});
    // ignore: invalid_use_of_protected_member
    c.read(codeStatusesProvider.notifier).state = {
      // The lead idles while its fork works.
      'a': SessionStatus.idle,
      'b': SessionStatus.needsInput,
      'c': SessionStatus.done,
      'f': SessionStatus.running,
    };
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: LayoutHost(
          language: DesignLanguage.material,
          child: ShellScope(sidebarVisible: true, compact: false, toggleSidebar: () {}, child: const BoardScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Finder inColumn(String col, String text) =>
        find.descendant(of: find.byKey(ValueKey('board.column.$col')), matching: find.text(text));
    expect(inColumn('running', 'Session a'), findsOneWidget);
    expect(inColumn('needsYou', 'Session b'), findsOneWidget);
    expect(inColumn('done', 'Session c'), findsOneWidget);
    // A fork stays off until detached (it shows in its lead's family tree meanwhile).
    expect(find.byKey(const ValueKey('board.slot.f')), findsNothing);
    expect(find.byKey(const ValueKey('board.work.f')), findsOneWidget);
    c.read(boardDetachedProvider.notifier).toggle('f');
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('board.column.running')),
        matching: find.byKey(const ValueKey('board.slot.f')),
      ),
      findsOneWidget,
    );
    // The lead idles while its fork works: Running, waiting on its own work.
    expect(find.text('Lead waiting · 1 fork running'), findsOneWidget);
    expect(jsonDecode(prefs[BoardDetached.key]!), ['f']);
    // A waiting session without a live controller can still be opened from its card.
    expect(find.byKey(const ValueKey('board.open.b')), findsOneWidget);

    // A workflow keeps its session under Running while the lead sits idle; the card moves back once it ends.
    const run = WorkflowRun(runId: 'r1', name: 'Security review');
    c.read(workflowRunsProvider('c').notifier).put(run);
    await tester.pumpAndSettle();
    expect(inColumn('running', 'Session c'), findsOneWidget);
    c
        .read(workflowRunsProvider('c').notifier)
        .put(const WorkflowRun(runId: 'r1', name: 'x', state: RunEnded(WorkflowOutcome.done)));
    await tester.pumpAndSettle();
    expect(inColumn('done', 'Session c'), findsOneWidget);

    // Done cards clear; one that runs again comes back.
    await tester.tap(find.byKey(const ValueKey('board.clear-done')));
    await tester.pumpAndSettle();
    expect(find.text('Session c'), findsNothing);
    expect(c.read(boardDismissedProvider), {'c'});
    // ignore: invalid_use_of_protected_member
    c.read(codeStatusesProvider.notifier).state = {...c.read(codeStatusesProvider), 'c': SessionStatus.running};
    await tester.pumpAndSettle();
    expect(inColumn('running', 'Session c'), findsOneWidget);
    expect(c.read(boardDismissedProvider), isEmpty);

    // A hairline between columns resizes them and remembers it.
    final before = tester.getSize(find.byKey(const ValueKey('board.column.needsYou'))).width;
    await tester.drag(find.byKey(const ValueKey('board.divider.0')), const Offset(80, 0), touchSlopX: 0);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const ValueKey('board.column.needsYou'))).width, closeTo(before + 80, 1));
    expect(c.read(boardColumnsProvider).first, greaterThan(1 / 3));
    expect(prefs[BoardColumns.key], isNotNull);

    await tester.tap(
      find.descendant(of: find.byKey(const ValueKey('board.filter')), matching: find.text('Claude Code')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Session a'), findsNothing);
    expect(find.text('Session b'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
    tester.view.reset();
    c.dispose();
    await db.close();
  });

  testWidgets('a card keeps its state as it glides to Done, its glow goes off and it bursts', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    final db = AppDatabase(NativeDatabase.memory());
    final prefs = await Preferences.load(db);
    prefs['code.projects'] = '[{"id":"p1","name":"Alpha","path":"/tmp/p1"}]';
    prefs[BoardMarks.doneSinceKey] = '{}';
    prefs['code.sessions'] = jsonEncode([_s('x').toJson()]);
    final c = ProviderContainer(overrides: [preferencesProvider.overrideWithValue(prefs)]);
    c.listen(codeStatusesProvider, (_, _) {});
    // ignore: invalid_use_of_protected_member
    c.read(codeStatusesProvider.notifier).state = {'x': SessionStatus.running};
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: LayoutHost(
          language: DesignLanguage.material,
          child: ShellScope(sidebarVisible: true, compact: false, toggleSidebar: () {}, child: const BoardScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final card = find.byKey(const ValueKey('board.card.x.0'));
    final before = tester.state(card);
    // ignore: invalid_use_of_protected_member
    c.read(codeStatusesProvider.notifier).state = {'x': SessionStatus.done};
    // Mid-glide (and mid-burst) it is the same card, not a new one.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.state(card), same(before));
    expect(find.byType(CustomPaint), findsWidgets);
    await tester.pumpAndSettle();
    expect(tester.state(card), same(before));
    expect(find.descendant(of: find.byKey(const ValueKey('board.column.done')), matching: card), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
    tester.view.reset();
    c.dispose();
    await db.close();
  });

  testWidgets('a first frame before any status has loaded clears and records nothing', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    final db = AppDatabase(NativeDatabase.memory());
    final prefs = await Preferences.load(db);
    prefs['code.projects'] = '[{"id":"p1","name":"Alpha","path":"/tmp/p1"}]';
    // Ten sessions the harness has not reported on yet (real directories: the poller would ask about them).
    final real = [for (var i = 0; i < 10; i++) _s('s$i', day: i + 1, dir: '/tmp/p1')];
    prefs['code.sessions'] = jsonEncode([for (final s in real) s.toJson()]);
    prefs[BoardMarks.doneSinceKey] = '{}';
    final c = ProviderContainer(overrides: [preferencesProvider.overrideWithValue(prefs)]);
    c.listen(codeStatusesLoadProvider, (_, _) {});
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: LayoutHost(
          language: DesignLanguage.material,
          child: ShellScope(sidebarVisible: true, compact: false, toggleSidebar: () {}, child: const BoardScreen()),
        ),
      ),
    );
    await tester.pump();
    expect(c.read(codeStatusesLoadProvider), isA<StatusesLoading>());
    expect(c.read(boardDismissedProvider), isEmpty);
    expect(prefs[BoardDismissed.key], isNull);
    expect(prefs[BoardMarks.doneSinceKey], '{}');
    expect(find.text('Session s0'), findsNothing);
    // Once the statuses are in, the real states apply: a running one is Running, the rest are Done.
    // ignore: invalid_use_of_protected_member
    c.read(codeStatusesProvider.notifier).state = {'s9': SessionStatus.running};
    c.read(codeStatusesLoadProvider.notifier).loaded();
    await tester.pumpAndSettle();
    expect(find.text('Session s9'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
    tester.view.reset();
    c.dispose();
    await db.close();
  });

  testWidgets("a closed fork's polled wait puts its lead under Needs you and opens the fork, not Running", (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    final db = AppDatabase(NativeDatabase.memory());
    final prefs = await Preferences.load(db);
    prefs['code.projects'] = '[{"id":"p1","name":"Alpha","path":"/tmp/p1"}]';
    prefs[BoardMarks.doneSinceKey] = '{}';
    prefs['code.sessions'] = jsonEncode([_s('lead').toJson(), _s('kid', parent: 'lead', dir: '/tmp/p1').toJson()]);
    final approval =
        (TranscriptBuilder()
              ..add(
                actionEvent(
                  id: 'x1',
                  toolName: 'bash',
                  kind: 'TerminalAction',
                  args: const {'command': 'rm -rf build/'},
                ),
              )
              ..add(stateEvent('x1-w', ExecutionStatus.waitingForConfirmation)))
            .snapshot;
    final c = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        codeSessionProvider.overrideWithBuild(
          (ref, n) =>
              n.sessionId == 'kid' ? CodeSessionState(connected: true, transcript: approval) : const CodeSessionState(),
        ),
      ],
    );
    c.listen(codeStatusesProvider, (_, _) {});
    c.listen(codeStatusesLoadProvider, (_, _) {});
    // After a restart: the fork has no controller, and the harness says it waits.
    // ignore: invalid_use_of_protected_member
    c.read(codeStatusesProvider.notifier).state = {'lead': SessionStatus.idle, 'kid': SessionStatus.needsInput};
    c.read(codeStatusesLoadProvider.notifier).loaded();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: LayoutHost(
          language: DesignLanguage.material,
          child: ShellScope(sidebarVisible: true, compact: false, toggleSidebar: () {}, child: const BoardScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Finder inColumn(String col, String text) =>
        find.descendant(of: find.byKey(ValueKey('board.column.$col')), matching: find.text(text));
    expect(inColumn('needsYou', 'Session lead'), findsOneWidget);
    expect(inColumn('running', 'Session lead'), findsNothing);
    // The fork was opened, so its wait shows under the lead with its controls.
    expect(c.exists(codeSessionProvider('kid')), isTrue);
    expect(find.byKey(const ValueKey('board.work.approve.kid')), findsOneWidget);
    expect(find.textContaining('Lead waiting'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
    tester.view.reset();
    c.dispose();
    await db.close();
  });

  testWidgets('a card lists its work; questions are open, and a child waiting on the user shows its controls', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    final db = AppDatabase(NativeDatabase.memory());
    final prefs = await Preferences.load(db);
    prefs['code.projects'] = '[{"id":"p1","name":"Alpha","path":"/tmp/p1"}]';
    // The Board has recorded finishes before: these count from now, not from when they started.
    prefs[BoardMarks.doneSinceKey] = '{}';
    prefs['code.sessions'] = jsonEncode([
      _s('a').toJson(),
      _s('q', day: 2).toJson(),
      _s('w1', parent: 'a').toJson(),
      _s('f1', parent: 'a').toJson(),
      _s('f2', parent: 'a').toJson(),
    ]);
    Transcript approval() =>
        (TranscriptBuilder()
              ..add(
                actionEvent(
                  id: 'x1',
                  toolName: 'bash',
                  kind: 'TerminalAction',
                  args: const {'command': 'rm -rf build/'},
                ),
              )
              ..add(stateEvent('x1-w', ExecutionStatus.waitingForConfirmation)))
            .snapshot;
    Transcript asking() {
      final b = TranscriptBuilder();
      b.addLocalQuestion(
        ActionCall(id: 'ask-1', raw: const {}, toolName: askUserQuestionTool, toolCallId: 'ask-1', action: const {}),
        const [
          Question(
            header: 'Database',
            question: 'Which database?',
            options: [QuestionOption('Postgres', ''), QuestionOption('SQLite', '')],
          ),
        ],
      );
      return b.snapshot;
    }

    final states = {
      'a': const CodeSessionState(connected: true, subagentNeedsInput: true),
      'q': CodeSessionState(connected: true, transcript: asking()),
      'w1': const CodeSessionState(connected: true),
      'f1': CodeSessionState(connected: true, transcript: approval()),
      'f2': const CodeSessionState(),
    };
    final c = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        codeSessionProvider.overrideWithBuild((ref, n) => states[n.sessionId] ?? const CodeSessionState()),
        workflowRunsProvider.overrideWithBuild(
          (ref, n) => n.sessionId == 'a'
              ? const [
                  WorkflowRun(
                    runId: 'r1',
                    name: 'Ultra',
                    agents: [
                      WorkflowAgentView(
                        key: 'k1',
                        label: 'research-1',
                        phase: 'build',
                        status: WorkflowAgentStatus.done,
                      ),
                      WorkflowAgentView(key: 'k2', label: 'research-2', phase: 'build', childId: 'w1'),
                    ],
                  ),
                ]
              : const [],
        ),
      ],
    );
    for (final id in states.keys) {
      c.listen(codeSessionProvider(id), (_, _) {});
    }
    c.listen(codeStatusesProvider, (_, _) {});
    // ignore: invalid_use_of_protected_member
    c.read(codeStatusesProvider.notifier).state = {'f2': SessionStatus.done};
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: LayoutHost(
          language: DesignLanguage.material,
          child: ShellScope(sidebarVisible: true, compact: false, toggleSidebar: () {}, child: const BoardScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // The question is open on its card, with no Answer step first.
    expect(find.text('Which database?'), findsOneWidget);
    expect(find.byKey(const ValueKey('board.answer.q')), findsNothing);

    // A child needs the user: the work list opens by itself, with its approval under its row.
    expect(find.textContaining('Ultra 1/2'), findsOneWidget);
    expect(find.textContaining('1 needs you'), findsOneWidget);
    expect(find.text('research-1'), findsOneWidget);
    expect(find.text('Session w1'), findsOneWidget);
    expect(find.text('Run this command?'), findsOneWidget);
    expect(find.text('rm -rf build/'), findsOneWidget);
    expect(find.byKey(const ValueKey('board.work.approve.f1')), findsOneWidget);
    expect(find.byKey(const ValueKey('board.work.deny.f1')), findsOneWidget);

    // It folds to one line.
    await tester.tap(find.byKey(const ValueKey('board.work.toggle.a')));
    await tester.pumpAndSettle();
    expect(find.text('Session w1'), findsNothing);
    expect(find.textContaining('1 needs you'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
    tester.view.reset();
    c.dispose();
    await db.close();
  });

  testWidgets('a card shows its phase: work in flight, unseen finishes, and warnings with their actions', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final db = AppDatabase(NativeDatabase.memory());
    final prefs = await Preferences.load(db);
    prefs['code.projects'] = '[{"id":"p1","name":"Alpha","path":"/tmp/p1"}]';
    // Three identical commands in a row: the lead is looping.
    final b = TranscriptBuilder();
    for (var i = 0; i < 3; i++) {
      b
        ..add(actionEvent(id: 'c$i', toolName: 'bash', kind: 'TerminalAction', args: const {'command': 'npm test'}))
        ..add(resultEvent(id: 'r$i', actionId: 'c$i', toolName: 'bash', text: 'fail'));
    }
    final looping = b.snapshot;
    final c = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        codeSessionProvider.overrideWithBuild(
          (ref, n) =>
              n.sessionId == 'l' ? CodeSessionState(connected: true, transcript: looping) : const CodeSessionState(),
        ),
      ],
    );
    c.listen(codeSessionProvider('l'), (_, _) {});
    Future<void> show(String id, BoardPhase phase, {BoardWorkCount work = noBoardWork}) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: LayoutHost(
            language: DesignLanguage.material,
            child: Center(
              child: SizedBox(
                width: 420,
                child: BoardCard(
                  key: ValueKey('$id.$phase'),
                  info: _s(id),
                  status: SessionStatus.done,
                  phase: phase,
                  work: work,
                  harnessLabel: 'EveryAI',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await show('a', BoardPhase.waitingOnWork, work: (forks: 3, subagents: 0, workflows: 0));
    expect(find.text('Lead waiting · 3 forks running'), findsOneWidget);
    expect(find.byKey(const ValueKey('board.unseen.a')), findsNothing);

    await show('a', BoardPhase.doneUnseen);
    expect(find.byKey(const ValueKey('board.unseen.a')), findsOneWidget);
    await show('a', BoardPhase.doneSeen);
    expect(find.byKey(const ValueKey('board.unseen.a')), findsNothing);

    // A looping lead: an amber line with Nudge and Stop; Compact only for a full context.
    await show('l', BoardPhase.working);
    expect(find.textContaining('Same step 3×'), findsOneWidget);
    expect(find.byKey(const ValueKey('board.nudge.l')), findsOneWidget);
    expect(find.byKey(const ValueKey('board.stop.l')), findsOneWidget);
    expect(find.byKey(const ValueKey('board.compact.l')), findsNothing);
    // The same session done: no warnings.
    await show('l', BoardPhase.doneSeen);
    expect(find.textContaining('Same step'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
    c.dispose();
    await db.close();
  });
}
