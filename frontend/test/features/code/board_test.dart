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
import 'package:every_ai/features/code/harness/events.dart';
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

  test('top-level sessions plus detached forks, newest first', () {
    final all = [_s('a', day: 1), _s('b', day: 3), _s('f', parent: 'a', day: 2), _s('g', parent: 'a', day: 4)];
    expect([for (final s in boardSessions(all, const {})) s.id], ['b', 'a']);
    expect(
      [
        for (final s in boardSessions(all, {'f'})) s.id,
      ],
      ['b', 'f', 'a'],
    );
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
}
