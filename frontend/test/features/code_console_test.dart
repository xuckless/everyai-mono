import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/drivers/usage_limit.dart';
import 'package:every_ai/features/code/git/git_service.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/ui/console/console_header.dart';
import 'package:every_ai/features/code/ui/console/context_breakdown.dart';
import 'package:every_ai/features/code/ui/console/git_button.dart';
import 'package:every_ai/features/code/ui/console/session_info_view.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/usage/usage_totals.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:every_ai/features/code/harness/events.dart' show PlanLimits, PlanWindow;
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart' as m;

/// A worktree removal that takes a while: the session leaves the list first, the rest waits on [gate].
final class _SlowDiscard extends CodeGit {
  _SlowDiscard(this.gate, super.sessionId);
  final Completer<void> gate;

  @override
  Future<GitSnapshot> build() async => const GitSnapshot();

  @override
  Future<void> discard({bool keepBranch = false}) async {
    await ref.read(codeSessionsProvider.notifier).remove(sessionId);
    await gate.future;
  }
}

class _FixedCatalog extends CatalogController {
  @override
  ModelCatalog build() => builtInCatalog;
}

const _worktree = SessionWorktree(
  repoRoot: '/repo',
  path: '/wt/fix',
  branch: 'everyai/fix-abc',
  baseBranch: 'main',
  baseCommit: 'abc123',
);

CodeSessionInfo _session(
  String id, {
  String? parentId,
  String workingDir = 'demo://counter-app',
  SessionWorktree? worktree,
  GitBaseline? baseline,
  bool pinned = false,
  String title = 'Fix the counter',
}) => CodeSessionInfo(
  id: id,
  projectId: 'p1',
  title: title,
  conversationId: 'conv-$id',
  model: 'anthropic/claude-haiku-5.5',
  mode: AgentMode.ask,
  workingDir: workingDir,
  createdAt: DateTime(2026),
  parentId: parentId,
  worktree: worktree,
  baseline: baseline,
  pinned: pinned,
);

void main() {
  test('the git button follows the work: commit, the open PR, create one, merge locally', () {
    GitAction? at({
      bool worktree = true,
      bool dirty = false,
      int ahead = 0,
      int behind = 0,
      bool remote = false,
      BranchPr? pr,
      String head = 'h1',
    }) => gitActionFor(
      worktree: worktree,
      dirty: dirty,
      ahead: ahead,
      behind: behind,
      base: 'dev',
      hasRemote: remote,
      pr: pr,
      head: head,
    );
    const pr = (number: 12, url: 'https://github.com/o/r/pull/12', open: true, head: 'h0');
    const merged = (number: 12, url: 'https://github.com/o/r/pull/12', open: false, head: 'h1');

    expect(at(worktree: false, dirty: true), isNull);
    expect(at(dirty: true, ahead: 2, remote: true, pr: pr)!.label, 'Commit');
    expect(at(ahead: 2, remote: true, pr: pr)!, (
      kind: GitActionKind.viewPr,
      label: 'View PR #12',
      enabled: true,
      url: pr.url,
    ));
    expect(at(ahead: 2, remote: true)!.kind, GitActionKind.createPr);
    // Squash-merged on GitHub: the commits still count as ahead, but another PR for them would be a duplicate.
    expect(at(ahead: 2, remote: true, pr: merged)!.label, 'View PR #12');
    expect(at(ahead: 3, remote: true, pr: merged, head: 'h2')!.kind, GitActionKind.createPr);
    // Merging locally: the agent prepares one commit on top of the base first, then the button merges it.
    expect(at(ahead: 2)!.kind, GitActionKind.prepareMerge);
    expect(at(ahead: 1, behind: 3)!.kind, GitActionKind.prepareMerge);
    expect(at(ahead: 1)!, (kind: GitActionKind.merge, label: 'Merge into dev', enabled: true, url: null));
    expect(at()!, (kind: GitActionKind.commit, label: 'Commit', enabled: false, url: null));
  });

  group('Session info', () {
    test('Context on the EveryAI harness: real totals, estimated parts, the rest named for what it is', () {
      final b = contextRows(
        used: 50000,
        limit: 200000,
        parts: [
          ContextPart(ContextKind.systemPrompt, 'x' * 4000),
          ContextPart(ContextKind.tools, 'y' * 800, name: 'bash'),
          ContextPart(ContextKind.mcpTools, 'z' * 400, name: 'github'),
          ContextPart(ContextKind.mcpTools, 'z' * 400, name: 'github'),
          ContextPart(ContextKind.mcpTools, 'z' * 400, name: 'linear'),
        ],
        outside: false,
        autoCompactPercent: 80,
      );
      final byLabel = {for (final r in b.rows) r.label: r};
      expect(byLabel['System prompt']!.tokens, 1000);
      expect(byLabel['System prompt']!.estimated, isTrue);
      expect(byLabel['MCP tools']!.children, [(name: 'github', tokens: 200), (name: 'linear', tokens: 100)]);
      expect(byLabel['Messages and tool results']!.tokens, 50000 - 1000 - 200 - 300);
      expect(byLabel['Autocompact buffer']!.tokens, 40000);
      expect(byLabel['Autocompact buffer']!.estimated, isFalse);
      expect(byLabel['Free space']!.tokens, 200000 - 50000 - 40000);
      expect(byLabel.keys, isNot(contains('Harness (not itemised)')));
    });

    test('usage lines: each plan window the lead reported, with its reset', () {
      final now = DateTime(2026, 11, 5, 12);
      final plan = PlanLimits.of(
        id: 'x',
        windows: [
          PlanWindow(name: 'seven_day', used: 0.35, resetsAt: DateTime(2026, 11, 5, 19, 59).toUtc(), minutes: 10080),
          const PlanWindow(name: 'five_hour', used: 0.1, minutes: 300),
        ],
      );
      final lines = usageLines(totals: UsageTotals.zero, plan: plan, outsideLabel: 'Claude Code', now: now);
      expect(lines, containsAllInOrder(['This week: 35% used · resets 19:59', '5-hour window: 10% used']));
      expect(lines.any((l) => l.contains('not reported')), isFalse);
      expect(planWindowName(const PlanWindow(name: 'seven_day_opus', used: 0, minutes: 10080)), 'This week (Opus)');
    });

    test('Usage shows a reached limit with its reset time, and says when a harness reports none', () {
      final now = DateTime(2026, 11, 4, 9);
      final lines = usageLines(
        totals: UsageTotals.zero,
        limit: UsageLimit(message: 'You hit your limit', resetsAt: DateTime(2026, 11, 4, 14, 5)),
        outsideLabel: 'Claude Code',
        now: now,
      );
      expect(lines, ['No model calls yet', 'No spending cap', 'Limit reached · resets 14:05']);
      expect(
        usageLines(totals: UsageTotals.zero, outsideLabel: 'Codex', budget: 5).last,
        'Plan limits: not reported by Codex',
      );
    });
  });

  group('console widgets', () {
    late AppDatabase db;
    late Preferences prefs;
    late ProviderContainer container;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      prefs = Preferences.inMemory();
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    Future<void> pump(
      WidgetTester tester,
      Widget child, {
      List<CodeSessionInfo> sessions = const [],
      Size? size,
      List<Override> extra = const [],
    }) async {
      prefs['code.sessions'] = jsonEncode([for (final s in sessions) s.toJson()]);
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(prefs),
          modelCatalogProvider.overrideWith(_FixedCatalog.new),
          codeUsageProvider.overrideWithBuild((ref, n) async => UsageTotals.zero),
          gitButtonProvider.overrideWith((ref, id) async => null),
          sessionRemoteLineProvider.overrideWithValue('Off'),
          ...extra,
        ],
      );
      if (size != null) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
      }
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => child),
          GoRoute(path: '/code', builder: (_, _) => const Text('code home')),
          GoRoute(path: '/code/s/:id', builder: (_, s) => Text('full ${s.pathParameters['id']}')),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: _app(null, router: router),
        ),
      );
      await tester.pump();
    }

    /// Unmounts the tree, so the panel's timers stop with the test.
    Future<void> unmount(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    }

    testWidgets('Delete in the title menu goes back to Code even when the screen goes first', (tester) async {
      final s = _session('s', workingDir: '/wt/fix', worktree: _worktree);
      final gate = Completer<void>();
      await pump(
        tester,
        Consumer(
          builder: (_, ref, _) {
            final info = ref.watch(codeSessionsProvider).firstOrNull;
            if (info == null) return const Text('gone');
            return Align(
              alignment: Alignment.topLeft,
              child: ConsoleTitle(info: info),
            );
          },
        ),
        sessions: [s],
        size: const Size(1000, 900),
        extra: [codeGitProvider.overrideWith2((id) => _SlowDiscard(gate, id))],
      );
      await tester.tap(find.text('Fix the counter'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('console.title.delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete').last);
      // Deleting stops the session's processes first (a real scan through the supervisor), so it takes real time.
      for (var i = 0; i < 100 && find.text('gone').evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      expect(find.text('gone'), findsOneWidget);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('code home'), findsOneWidget);
      await unmount(tester);
    });
  });
}

Widget _app(Widget? home, {GoRouter? router}) {
  Widget themed(Widget child) => m.Material(
    child: EveryThemeScope(theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light), child: child),
  );
  if (router != null) return m.MaterialApp.router(routerConfig: router, builder: (_, child) => themed(child!));
  return m.MaterialApp(home: themed(home!));
}
