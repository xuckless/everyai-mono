import 'dart:convert';

import 'package:drift/native.dart';
import 'package:every_ai/app/shell.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/features/code/board/board_providers.dart';
import 'package:every_ai/features/code/board/board_screen.dart';
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

CodeSessionInfo _s(String id, {String harness = everyaiHarnessName, String? parent, int day = 1}) => CodeSessionInfo(
  id: id,
  projectId: 'p1',
  title: 'Session $id',
  conversationId: 'c-$id',
  model: 'a/m',
  mode: AgentMode.ask,
  // Demo sessions: the status poller leaves them alone.
  workingDir: 'demo://p1',
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
      'a': SessionStatus.running,
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
    // A fork stays off until detached.
    expect(find.text('Session f'), findsNothing);
    c.read(boardDetachedProvider.notifier).toggle('f');
    await tester.pumpAndSettle();
    expect(inColumn('running', 'Session f'), findsOneWidget);
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

  testWidgets('a card lists its work; questions are open, and a child waiting on the user shows its controls', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    final db = AppDatabase(NativeDatabase.memory());
    final prefs = await Preferences.load(db);
    prefs['code.projects'] = '[{"id":"p1","name":"Alpha","path":"/tmp/p1"}]';
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
}
