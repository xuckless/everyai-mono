import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:every_ai/app/shell.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/net/api_client.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart' show apiClientProvider;
import 'package:every_ai/features/usage/usage_totals.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:every_ai/core/ui/anchored_popover.dart' show PopoverRow;
import 'package:every_ai/features/code/board/board_providers.dart';
import 'package:every_ai/features/code/board/board_screen.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/drivers/driver_events.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/live/agent_logins.dart';
import 'package:every_ai/features/code/ui/panes/login_ask_card.dart';
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

void main() {
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

    // A hairline between columns resizes them and remembers it (the Plan lane takes 333pt on the left).
    final before = tester.getSize(find.byKey(const ValueKey('board.column.needsYou'))).width;
    await tester.drag(find.byKey(const ValueKey('board.divider.0')), const Offset(60, 0), touchSlopX: 0);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const ValueKey('board.column.needsYou'))).width, closeTo(before + 60, 1));
    expect(c.read(boardColumnsProvider).first, greaterThan(1 / 3));
    expect(prefs[BoardColumns.key], isNotNull);

    // Three harnesses in the test font don't fit beside the search: the filter is a menu.
    await tester.tap(find.byKey(const ValueKey('board.filter.menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopoverRow, 'Claude Code'));
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
        boardResumeProvider.overrideWithValue((id) async {
          decisions.add('$id resume');
          return null;
        }),
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

  testWidgets("a fork's saved-login ask shows on its lead's card, naming the fork, and is answered there", (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    final prefs = await Preferences.load(db);
    prefs['code.sessions'] = jsonEncode([_s('lead').toJson(), _s('kid', parent: 'lead').toJson()]);
    final c = ProviderContainer(overrides: [preferencesProvider.overrideWithValue(prefs)]);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: LayoutHost(
          language: DesignLanguage.material,
          child: const Column(children: [LoginAskCard(sessionId: 'lead')]),
        ),
      ),
    );
    final asked = LoginGate.of('kid').ensure('github', site: 'github.com');
    await tester.pumpAndSettle();
    expect(find.textContaining('"Session kid" wants your saved login for github.com'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('login-ask.allow.kid.github')));
    await tester.pumpAndSettle();
    expect(await asked, ConsentOutcome.allowed);
    expect(find.textContaining('wants your saved login'), findsNothing);
    LoginGate.forget('kid');
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await db.close();
  });
}
