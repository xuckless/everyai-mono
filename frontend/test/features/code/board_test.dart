import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:every_ai/app/shell.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/net/api_client.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart' show apiClientProvider;
import 'package:every_ai/features/usage/usage_totals.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:every_ai/core/ui/kit.dart' show KitButton;
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
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart';
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

  /// A Board over [sessions] where the sessions in [live] have open controllers with those states; the Board's
  /// approvals are recorded in [decisions] instead of reaching a harness.
  Future<ProviderContainer> board(
    WidgetTester tester, {
    required List<CodeSessionInfo> sessions,
    required Map<String, CodeSessionState> live,
    required Map<String, SessionStatus> statuses,
    required List<String> decisions,
    Size size = const Size(1600, 900),
  }) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final prefs = await Preferences.load(db);
    prefs['code.projects'] = '[{"id":"p1","name":"Alpha","path":"/tmp/p1"}]';
    prefs[BoardMarks.doneSinceKey] = '{}';
    prefs['code.sessions'] = jsonEncode([for (final s in sessions) s.toJson()]);
    final c = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        // The inspector's composer reads usage and the server: neither is reached here.
        codeUsageProvider.overrideWithBuild((ref, n) async => UsageTotals.zero),
        apiClientProvider.overrideWithValue(
          ApiClient(
            baseUrl: Uri.parse('http://backend/'),
            client: MockClient((req) async => http.Response('no network in this test', 599)),
          ),
        ),
        codeSessionProvider.overrideWithBuild((ref, n) => live[n.sessionId] ?? const CodeSessionState()),
        boardDecideProvider.overrideWithValue(
          (id, {required approve, required callIds}) async =>
              decisions.add('$id ${approve ? 'approve' : 'deny'} ${callIds.join(',')}'),
        ),
      ],
    );
    for (final id in live.keys) {
      c.listen(codeSessionProvider(id), (_, _) {});
    }
    c.listen(codeStatusesProvider, (_, _) {});
    // ignore: invalid_use_of_protected_member
    c.read(codeStatusesProvider.notifier).state = statuses;
    c.listen(codeStatusesLoadProvider, (_, _) {});
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
    return c;
  }

  Transcript waitingOn(List<(String, String)> calls) {
    final b = TranscriptBuilder();
    for (final (id, command) in calls) {
      b.add(actionEvent(id: id, toolName: 'bash', kind: 'TerminalAction', args: {'command': command}));
    }
    b.add(stateEvent('${calls.first.$1}-w', ExecutionStatus.waitingForConfirmation));
    return b.snapshot;
  }

  // The inspector's status and composer animate for as long as they show: fixed steps, not "settled".
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> done(WidgetTester tester, ProviderContainer c) async {
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    debugDefaultTargetPlatformOverride = null;
    tester.view.reset();
  }

  testWidgets(
    'keys move a selection, the inspector follows it and a/d act on what it shows; a click lets the composer type; '
    'Approve all confirms risky calls once',
    (tester) async {
      final decisions = <String>[];
      final c = await board(
        tester,
        sessions: [_s('n'), _s('d1', day: 2), _s('d2', day: 3), _s('d3', day: 4)],
        live: {
          'n': CodeSessionState(connected: true, transcript: waitingOn([('x1', 'rm -rf ~')])),
        },
        statuses: {'d1': SessionStatus.done, 'd2': SessionStatus.done, 'd3': SessionStatus.done},
        decisions: decisions,
      );
      await settle(tester);
      expect(tester.takeException(), isNull);
      Border? ring(String id) =>
          (tester.widget<DecoratedBox>(find.byKey(ValueKey('board.ring.$id'))).decoration as BoxDecoration).border
              as Border?;
      bool selected(String id) => ring(id)?.top.width == 1.5 && ring(id)!.top.color.a > 0.9;
      Finder inspector(String id) => find.byKey(ValueKey('board.inspector.$id'));
      final reply = find.descendant(
        of: find.byKey(const ValueKey('board.inspector.composer.n')),
        matching: find.byType(EditableText),
      );

      // j walks the cards in order (Needs you first, Done newest first); n jumps to the one that needs you.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await tester.pump();
      expect(selected('n'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await tester.pump();
      expect(selected('n'), isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pump();
      expect(selected('n'), isTrue);

      // Enter opens the inspector beside the columns, with the approval; the Board keeps the keys.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(inspector('n'), findsOneWidget);
      expect(
        find.descendant(of: inspector('n'), matching: find.textContaining('rm -rf ~', findRichText: true)),
        findsWidgets,
      );
      expect(find.byKey(const ValueKey('board.column.needsYou')), findsOneWidget);
      expect(tester.widget<EditableText>(reply).focusNode.hasFocus, isFalse);
      // j carries the inspector to the next card, and a/d then act on what it shows (d3 waits on nothing).
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await settle(tester);
      expect(inspector('n'), findsNothing);
      expect(inspector('d3'), findsOneWidget);
      expect(selected('d3'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pump();
      expect(decisions, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await settle(tester);
      expect(inspector('n'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pump();
      expect(decisions, ['n approve x1']);
      decisions.clear();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(inspector('n'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(selected('n'), isFalse);

      // A click opens it with the composer taking the keys: "a" typed there is text, not Approve.
      await tester.tap(find.text('Session n'));
      await settle(tester);
      expect(inspector('n'), findsOneWidget);
      expect(tester.widget<EditableText>(reply).focusNode.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA, character: 'A');
      await tester.pump();
      expect(decisions, isEmpty);
      // A reply goes to the session (queued, as the agent waits on an approval).
      await tester.enterText(reply, 'just checking');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect([for (final q in c.read(codeSessionProvider('n')).queued) q.text], ['just checking']);
      // Esc with a draft closes the inspector and keeps the draft for the next look.
      await tester.enterText(reply, 'half a thought');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(inspector('n'), findsNothing);
      await tester.tap(find.text('Session n'));
      await settle(tester);
      expect(tester.widget<EditableText>(reply).controller.text, 'half a thought');
      await tester.tap(find.byKey(const ValueKey('board.inspector.close')));
      await settle(tester);
      expect(inspector('n'), findsNothing);

      // In the filter field, Board keys are text: "a" there approves nothing.
      await tester.sendKeyEvent(LogicalKeyboardKey.slash, character: '/');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pump();
      expect(decisions, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      // Approve all: the flagged call is listed (with what it runs) in one confirm; Cancel approves nothing.
      await tester.tap(find.byKey(const ValueKey('board.approve-all')));
      await settle(tester);
      expect(find.text('Approve all, risky ones included?'), findsOneWidget);
      expect(find.textContaining('rm -rf ~'), findsWidgets);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(decisions, isEmpty);
      // While one run is confirming, the button takes no second press; confirm once, then it approves x1.
      await tester.tap(find.byKey(const ValueKey('board.approve-all')));
      await tester.pump();
      expect(tester.widget<KitButton>(find.byKey(const ValueKey('board.approve-all'))).onPressed, isNull);
      await settle(tester);
      await tester.tap(find.text('Approve all').last);
      await settle(tester);
      expect(decisions, ['n approve x1']);
      expect(find.text('Approved 1 call'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      decisions.clear();

      // A click that drifts a few pixels on Approve still approves (no sweep takes it).
      final approve = tester.getCenter(find.byKey(const ValueKey('board.approve.n')));
      final press = await tester.startGesture(approve, kind: PointerDeviceKind.mouse);
      await press.moveTo(approve + const Offset(3, 2));
      await press.up();
      await tester.pump();
      expect(decisions, ['n approve x1']);

      await done(tester, c);
    },
  );

  testWidgets('clicking the inspected card again gives its composer the keys: typing a reply approves nothing', (
    tester,
  ) async {
    final decisions = <String>[];
    final c = await board(
      tester,
      sessions: [_s('n')],
      live: {
        'n': CodeSessionState(connected: true, transcript: waitingOn([('x1', 'ls')])),
      },
      statuses: const {},
      decisions: decisions,
    );
    await settle(tester);
    final reply = find.descendant(
      of: find.byKey(const ValueKey('board.inspector.composer.n')),
      matching: find.byType(EditableText),
    );
    // From the keyboard the Board keeps the keys; then a click on empty Board space, then on the same card.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(tester.widget<EditableText>(reply).focusNode.hasFocus, isFalse);
    await tester.tap(find.byKey(const ValueKey('board.card.n.0')));
    await settle(tester);
    expect(tester.widget<EditableText>(reply).focusNode.hasFocus, isTrue);
    await tester.tapAt(const Offset(300, 700));
    await settle(tester);
    expect(tester.widget<EditableText>(reply).focusNode.hasFocus, isFalse);
    await tester.tap(find.byKey(const ValueKey('board.card.n.0')));
    await settle(tester);
    expect(tester.widget<EditableText>(reply).focusNode.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    expect(decisions, isEmpty);

    await done(tester, c);
  });

  testWidgets('looking at closed Done cards with j/k attaches no controller; Reply does', (tester) async {
    final c = await board(
      tester,
      sessions: [_s('d1', day: 2), _s('d2', day: 3), _s('d3', day: 4)],
      live: const {},
      statuses: {'d1': SessionStatus.done, 'd2': SessionStatus.done, 'd3': SessionStatus.done},
      decisions: [],
    );
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    for (var i = 0; i < 2; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await settle(tester);
    }
    expect(find.byKey(const ValueKey('board.inspector.d1')), findsOneWidget);
    for (final id in ['d1', 'd2', 'd3']) {
      expect(c.exists(codeSessionProvider(id)), isFalse, reason: id);
    }
    await tester.tap(find.byKey(const ValueKey('board.inspector.reply')));
    await settle(tester);
    expect(c.exists(codeSessionProvider('d1')), isTrue);
    expect(find.byKey(const ValueKey('board.inspector.composer.d1')), findsOneWidget);

    await done(tester, c);
  });

  testWidgets('one answer per session at a time: a second Approve while one is in flight is dropped', (tester) async {
    final gate = Completer<void>();
    final sent = <String>[];
    final c = await board(
      tester,
      sessions: [_s('n')],
      live: {
        'n': CodeSessionState(connected: true, transcript: waitingOn([('x1', 'ls')])),
      },
      statuses: const {},
      decisions: [],
    );
    final deciding = c.read(boardDecidingProvider);
    final first = decideOnce(
      deciding,
      (id, {required approve, required callIds}) async {
        sent.add(id);
        await gate.future;
      },
      'n',
      approve: true,
      callIds: ['x1'],
    );
    expect(
      await decideOnce(
        deciding,
        (id, {required approve, required callIds}) async => sent.add('again'),
        'n',
        approve: true,
        callIds: ['x1'],
      ),
      isFalse,
    );
    gate.complete();
    expect(await first, isTrue);
    expect(sent, ['n']);
    expect(deciding, isEmpty);

    await done(tester, c);
  });

  testWidgets('a sweep clears Done cards with Undo (as they were); a drifting click opens one; held x clears once', (
    tester,
  ) async {
    final c = await board(
      tester,
      sessions: [_s('d1', day: 2), _s('d2', day: 3), _s('d3', day: 4)],
      live: const {},
      statuses: {'d1': SessionStatus.done, 'd2': SessionStatus.done, 'd3': SessionStatus.done},
      decisions: [],
    );
    await settle(tester);

    // A click that drifts a little on a Done card opens it; it clears nothing.
    final d1 = tester.getCenter(find.text('Session d1'));
    final click = await tester.startGesture(d1, kind: PointerDeviceKind.mouse);
    await click.moveTo(d1 + const Offset(3, 1));
    await click.up();
    await settle(tester);
    expect(c.read(boardDismissedProvider), isEmpty);
    expect(find.byKey(const ValueKey('board.inspector.d1')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('board.inspector.close')));
    await settle(tester);

    // A mouse sweep from the first Done card to the third clears all three; Undo brings them back as they were.
    final since = Map.of(c.read(boardMarksProvider).marks);
    expect(since.keys, containsAll(['d1', 'd2', 'd3']));
    final from = tester.getCenter(find.text('Session d3'));
    final to = tester.getCenter(find.text('Session d1'));
    final mouse = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
    await mouse.moveTo(from + const Offset(0, 30));
    await tester.pump();
    await mouse.moveTo(to);
    await tester.pump();
    await mouse.up();
    await settle(tester);
    expect(c.read(boardDismissedProvider), {'d1', 'd2', 'd3'});
    expect(find.text('Session d2'), findsNothing);
    expect(find.text('Cleared 3'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('board.undo')));
    await settle(tester);
    expect(c.read(boardDismissedProvider), isEmpty);
    expect(find.text('Session d2'), findsOneWidget);
    expect(c.read(boardMarksProvider).marks, since);

    // A held x clears the selected card once, not its neighbours as the selection moves on; ⌘Z takes it back.
    await tester.tap(find.text('Session d2'));
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyX);
    await tester.pump();
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyX);
      await tester.pump();
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyX);
    await settle(tester);
    expect(c.read(boardDismissedProvider), {'d2'});
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await settle(tester);
    expect(c.read(boardDismissedProvider), isEmpty);

    // The filter narrows the cards; Esc clears it.
    await tester.sendKeyEvent(LogicalKeyboardKey.slash, character: '/');
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('board.search')), 'd2');
    await settle(tester);
    expect(find.text('Session d1'), findsNothing);
    expect(find.text('Session d2'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(find.text('Session d1'), findsOneWidget);

    await done(tester, c);
  });

  testWidgets('an inspector covering the Board keeps keys off the hidden cards; a/d skip calls decided one by one; '
      'Approve all across sessions always confirms', (tester) async {
    final decisions = <String>[];
    final c = await board(
      tester,
      sessions: [_s('p', day: 2), _s('q')],
      live: {
        // x1 was denied in the per-call menu; only x2 still waits on an answer.
        'p': CodeSessionState(
          connected: true,
          transcript: waitingOn([('x1', 'rm -rf build'), ('x2', 'ls')]),
          decided: const {'x1': false},
        ),
        'q': CodeSessionState(connected: true, transcript: waitingOn([('y1', 'pwd')])),
      },
      statuses: const {},
      decisions: decisions,
      size: const Size(820, 900),
    );
    await settle(tester);

    // Narrow: Enter opens the inspector over the Board; j and a don't reach the hidden cards.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(find.byKey(const ValueKey('board.inspector.back')), findsOneWidget);
    final shown = find.byKey(const ValueKey('board.inspector.p'));
    expect(shown, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await settle(tester);
    expect(shown, findsOneWidget);
    expect(decisions, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(shown, findsNothing);

    // a answers only the call still undecided; the denied one keeps its answer.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    expect(decisions, ['p approve x2']);
    decisions.clear();

    // Approve all over two sessions confirms even with nothing flagged; Cancel sends nothing.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA, character: 'A');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await settle(tester);
    expect(find.textContaining('in 2 sessions'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(decisions, isEmpty);

    await done(tester, c);
  });
}
