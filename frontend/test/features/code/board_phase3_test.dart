import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/features/code/board/board_limits.dart';
import 'package:every_ai/features/code/board/board_pr.dart';
import 'package:every_ai/features/code/board/board_snooze.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/drivers/driver_events.dart' show stateEvent;
import 'package:every_ai/features/code/drivers/usage_limit.dart';
import 'package:every_ai/features/code/git/git_service.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/usage/usage_totals.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../layout/layout_host.dart';

// Board v2, phase 3: the limits strip, cost on cards, snooze and resume at a limit's reset, and pull request chips.

CodeSessionInfo _s(String id, {String dir = '/tmp/p1', int? pr, String branch = '', int day = 1}) => CodeSessionInfo(
  id: id,
  projectId: 'p1',
  title: 'Session $id',
  conversationId: 'c-$id',
  model: 'a/m',
  mode: AgentMode.ask,
  workingDir: dir,
  createdAt: DateTime(2026, 11, day),
  prNumber: pr,
  branch: branch,
);

void main() {
  group('limits strip', () {
    final now = DateTime.utc(2026, 11, 11, 12);
    PlanLimits plan(List<PlanWindow> w) => PlanLimits.of(id: 'x', windows: w);

    test('one bar per harness and window, the latest reading, fullest first; passed windows left out', () {
      final pooled = poolPlanLimits([
        (
          sessionId: 'a',
          harness: 'claude-code',
          harnessLabel: 'Claude Code',
          account: 'host',
          plan: plan([
            PlanWindow(name: 'seven_day', used: 0.40, resetsAt: now.add(const Duration(days: 2)), minutes: 10080),
            // Reset already: says nothing about now.
            PlanWindow(name: 'five_hour', used: 0.99, resetsAt: now.subtract(const Duration(minutes: 1)), minutes: 300),
          ]),
        ),
        (
          sessionId: 'b',
          harness: 'claude-code',
          harnessLabel: 'Claude Code',
          account: 'host',
          plan: plan([
            // The same window, read later: more used.
            PlanWindow(name: 'seven_day', used: 0.76, resetsAt: now.add(const Duration(days: 2)), minutes: 10080),
          ]),
        ),
        (
          sessionId: 'c',
          harness: 'codex',
          harnessLabel: 'Codex',
          account: 'host',
          plan: plan([PlanWindow(name: 'codex/primary', used: 0.9, resetsAt: now.add(const Duration(hours: 2)))]),
        ),
      ], now: now);
      expect([for (final l in pooled) (l.label, l.percent)], [('Codex', 90), ('Claude Code', 76)]);
      expect(
        [for (final l in pooled) l.sessions],
        [
          ['c'],
          ['a', 'b'],
        ],
      );
      expect(pooled.last.scope, 'This week');
    });

    test('a session in another environment may be another account: its own bar', () {
      final pooled = poolPlanLimits([
        for (final (id, account, used) in [('a', 'host', 0.2), ('b', 'wsl:Ubuntu', 0.7)])
          (
            sessionId: id,
            harness: 'claude-code',
            harnessLabel: 'Claude Code',
            account: account,
            plan: plan([PlanWindow(name: 'seven_day', used: used, resetsAt: now.add(const Duration(days: 1)))]),
          ),
      ], now: now);
      expect([for (final l in pooled) (l.label, l.percent)], [('Claude Code · wsl:Ubuntu', 70), ('Claude Code', 20)]);
    });

    test('the Board looks again at the earliest change to come; one already due is now', () {
      expect(
        earliest([null, now.add(const Duration(hours: 2)), now.add(const Duration(minutes: 5))], after: now),
        now.add(const Duration(minutes: 5)),
      );
      expect(earliest([now.subtract(const Duration(minutes: 1))], after: now), now);
      expect(earliest(const [null], after: now), isNull);
    });

    test('a new window beats a fuller old one; the busiest cap is the one shown', () {
      final pooled = poolPlanLimits([
        (
          sessionId: 'a',
          harness: 'codex',
          harnessLabel: 'Codex',
          account: 'host',
          plan: plan([PlanWindow(name: 'w', used: 0.95, resetsAt: now.add(const Duration(minutes: 5)))]),
        ),
        (
          sessionId: 'b',
          harness: 'codex',
          harnessLabel: 'Codex',
          account: 'host',
          plan: plan([PlanWindow(name: 'w', used: 0.05, resetsAt: now.add(const Duration(hours: 5)))]),
        ),
      ], now: now);
      expect(pooled.single.percent, 5);

      final cap = busiestCap([
        (sessionId: 'a', title: 'A', spentMicros: 1000000, budgetUsd: 5),
        (sessionId: 'b', title: 'B', spentMicros: 4000000, budgetUsd: 5),
        (sessionId: 'c', title: 'C', spentMicros: 9000000, budgetUsd: null),
      ])!;
      expect((cap.label, cap.scope, cap.percent), ('Session cap', r'B · $5.00', 80));
      expect(cap.sessions, ['b']);
      expect(busiestCap(const []), isNull);
    });

    test('a card says what it cost, or its tokens on the plan', () {
      expect(boardCostLine(UsageTotals.zero), '');
      expect(boardCostLine(const UsageTotals(calls: 2, promptTokens: 1000, chargedMicros: 420000)), r'$0.42');
      expect(boardCostLine(const UsageTotals(calls: 2, promptTokens: 42400000, planCalls: 2)), '42.4M on your plan');
    });
  });

  group('snooze and resume', () {
    final now = DateTime(2026, 11, 11, 12);
    final reset = now.add(const Duration(hours: 1, minutes: 12));

    test('limited → snoozed → ready to resume; never ready before the reset', () {
      final limit = UsageLimit(message: 'You hit your limit', resetsAt: reset);
      expect(boardLimitState(now: now), isA<NotLimited>());
      expect(boardLimitState(limit: limit, now: now), isA<Limited>().having((l) => l.resetsAt, 'resetsAt', reset));
      expect(boardLimitState(limit: limit, snoozedUntil: reset, now: now), isA<Snoozed>());
      expect(boardLimitState(limit: limit, snoozedUntil: reset, now: reset), isA<ReadyToResume>());
      expect(boardLimitState(limit: limit, now: reset.add(const Duration(minutes: 1))), isA<ReadyToResume>());
      // A limit with no known reset can't be snoozed; Resume is offered at once.
      expect(
        boardLimitState(
          limit: const UsageLimit(message: 'out'),
          now: now,
        ),
        isA<ReadyToResume>().having((r) => r.resetKnown, 'resetKnown', false),
      );
    });

    test('a transcript is read only once connected and replayed', () {
      expect(transcriptSettled(connected: false, transcript: const Transcript()), isFalse);
      expect(transcriptSettled(connected: true, transcript: const Transcript()), isFalse);
    });

    test('countdown text', () {
      expect(resetsInText(const Duration(hours: 1, minutes: 12)), 'Resets in 1h 12m');
      expect(resetsInText(const Duration(minutes: 4, seconds: 30)), 'Resets in 4m');
      expect(resetsInText(const Duration(seconds: 20)), 'Resets in under a minute');
      expect(resetsInText(const Duration(hours: 2)), 'Resets in 2h');
      expect(resetsInText(const Duration(days: 2, hours: 3), prefix: 'Back in'), 'Back in 2d 3h');
    });

    test('the transcript ends on a limit only while nothing runs since', () {
      final b = TranscriptBuilder()..add(usageLimitEvent('l1', 'Out of messages', resetsAt: reset));
      expect(stoppedOnLimit(b.snapshot)?.resetsAt, reset.toUtc());
      b.add(stateEvent('s1', ExecutionStatus.running));
      expect(stoppedOnLimit(b.snapshot), isNull);
    });
  });

  group('pull request chip', () {
    test('gh JSON: state, checks, review, mergeable and line counts', () {
      final pr = parsePrStatus(
        '{"number":12,"url":"https://github.com/o/r/pull/12","state":"OPEN","isDraft":false,"mergeable":"MERGEABLE",'
        '"reviewDecision":"APPROVED","additions":120,"deletions":30,"statusCheckRollup":['
        '{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},'
        '{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SKIPPED"},'
        '{"__typename":"StatusContext","state":"SUCCESS"}]}',
      )!;
      expect(
        (pr.number, pr.state, pr.checks, pr.review, pr.mergeable),
        (12, PrState.open, PrChecks.passing, PrReview.approved, true),
      );
      expect(pr.readyToMerge, isTrue);
      expect(prChipText(pr, done: true), (checks: 'Checks pass', review: 'Approved', ready: 'Ready to merge +120 −30'));
      expect(prChipText(pr, done: false).ready, '');
      expect(parsePrStatus('not json'), isNull);
      expect(parsePrStatus('{"number":1}'), isNull);
    });

    test('ready to merge only when GitHub would merge it now', () {
      PrStatus pr({PrChecks checks = PrChecks.passing, PrReview review = PrReview.approved, String state = ''}) =>
          PrStatus(
            number: 1,
            url: 'u',
            state: PrState.open,
            mergeable: true,
            checks: checks,
            review: review,
            mergeState: state,
          );
      expect(pr().readyToMerge, isTrue);
      expect(pr(checks: PrChecks.none, review: PrReview.none, state: 'CLEAN').readyToMerge, isTrue);
      expect(pr(state: 'HAS_HOOKS').readyToMerge, isTrue);
      expect(pr(checks: PrChecks.pending).readyToMerge, isFalse);
      expect(pr(review: PrReview.required).readyToMerge, isFalse);
      for (final blocked in ['BLOCKED', 'BEHIND', 'UNSTABLE', 'DIRTY']) {
        expect(pr(state: blocked).readyToMerge, isFalse, reason: blocked);
      }
      final parsed = parsePrStatus(
        '{"number":2,"url":"u","state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","headRefOid":"abc"}',
      )!;
      expect((parsed.mergeState, parsed.head, parsed.readyToMerge), ('BLOCKED', 'abc', false));
      expect(ghSaysNoPr('no pull requests found for branch "x"'), isTrue);
      expect(ghSaysNoPr('HTTP 502: Bad Gateway'), isFalse);
      expect(ghSaysNoPr('API rate limit exceeded'), isFalse);
    });

    test('every card shares one sign-in check and at most two gh calls at once', () async {
      var readies = 0;
      var running = 0;
      var most = 0;
      final hold = Completer<void>();
      final gate = BoardGhGate((
        ready: (_) async {
          readies++;
          return true;
        },
        status: (_, _) async {
          running++;
          most = running > most ? running : most;
          await hold.future;
          running--;
          return null;
        },
        method: (_, _) async => PrMergeMethod.squash,
        blocker: (_, _) async => null,
        merge: (_, _, _) async {},
      ));
      await Future.wait([for (var i = 0; i < 4; i++) gate.ready('d')]);
      expect(readies, 1);
      final asks = [for (var i = 0; i < 5; i++) gate.status('d', 't$i')];
      await pumpEventQueue();
      expect(most, 2);
      hold.complete();
      await Future.wait(asks);
      expect(most, 2);
    });

    test('checks: one failure fails them, anything running keeps them pending', () {
      expect(prChecksOf(const []), PrChecks.none);
      expect(
        prChecksOf(const [
          {'status': 'IN_PROGRESS'},
          {'status': 'COMPLETED', 'conclusion': 'SUCCESS'},
        ]),
        PrChecks.pending,
      );
      expect(
        prChecksOf(const [
          {'status': 'IN_PROGRESS'},
          {'state': 'FAILURE'},
        ]),
        PrChecks.failing,
      );
      final draft = parsePrStatus('{"number":3,"url":"u","state":"OPEN","isDraft":true,"mergeable":"MERGEABLE"}')!;
      expect((draft.state, draft.readyToMerge), (PrState.draft, false));
      final conflicting = parsePrStatus('{"number":4,"url":"u","state":"OPEN","mergeable":"CONFLICTING"}')!;
      expect(conflicting.readyToMerge, isFalse);
    });

    test("merge uses the pull request's repository's way; targets and poll delays", () {
      expect(
        prMergeMethodOf('{"mergeCommitAllowed":true,"squashMergeAllowed":true,"rebaseMergeAllowed":true}'),
        PrMergeMethod.squash,
      );
      expect(prMergeMethodOf('{"mergeCommitAllowed":true}'), PrMergeMethod.merge);
      expect(prMergeMethodOf('{"rebaseMergeAllowed":true}'), PrMergeMethod.rebase);
      expect(prMergeMethodOf(''), PrMergeMethod.squash);
      expect(const PrStatus(number: 1, url: 'https://github.com/o/r/pull/1', state: PrState.open).repo, 'o/r');
      expect(const PrStatus(number: 1, url: 'u', state: PrState.open).repo, '');
      expect(prTarget(_s('a', pr: 7)), '7');
      expect(prTarget(_s('a', branch: 'feature/x')), 'feature/x');
      expect(prTarget(_s('a', branch: 'main')), isNull);
      expect(prTarget(_s('a', dir: 'demo://p1', pr: 7)), isNull);
      expect(prPollDelay(found: true, failures: 0), const Duration(minutes: 1));
      expect(prPollDelay(found: false, failures: 0), const Duration(minutes: 5));
      expect(prPollDelay(found: true, failures: 1), const Duration(minutes: 1));
      expect(prPollDelay(found: true, failures: 3), const Duration(minutes: 4));
      expect(prPollDelay(found: true, failures: 9), const Duration(minutes: 10));
    });

    testWidgets('the chip shows the pull request; Merge asks first and runs once', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final db = AppDatabase(NativeDatabase.memory());
      final prefs = await Preferences.load(db);
      final session = _s('a', pr: 12);
      prefs['code.sessions'] = jsonEncode([session.toJson()]);
      const pr = PrStatus(
        number: 12,
        url: 'u',
        state: PrState.open,
        checks: PrChecks.passing,
        review: PrReview.approved,
        mergeable: true,
        additions: 5,
        deletions: 1,
      );
      final merges = <(int, PrMergeMethod)>[];
      final mergeGate = Completer<void>();
      String? blocker = 'The session has changes that aren\'t committed and pushed. Commit and push them first.';
      final c = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          boardPrSourceProvider.overrideWithValue((
            ready: (_) async => true,
            status: (_, _) async => merges.isEmpty ? pr : pr.withState(PrState.merged),
            method: (_, _) async => PrMergeMethod.squash,
            blocker: (_, _) async => blocker,
            merge: (_, p, m) async {
              merges.add((p.number, m));
              await mergeGate.future;
            },
          )),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: LayoutHost(
            language: DesignLanguage.material,
            child: Center(
              child: SizedBox(width: 420, child: BoardPrChip(info: session, done: true)),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(find.text('PR #12'), findsOneWidget);
      expect(find.text('Checks pass'), findsOneWidget);
      expect(find.text('Ready to merge +5 −1'), findsOneWidget);

      // Something unpushed in the session: the reason instead.
      await tester.tap(find.byKey(const ValueKey('board.pr.merge.a')));
      await tester.pumpAndSettle();
      expect(find.text('Merge pull request #12?'), findsNothing);
      expect(merges, isEmpty);
      await tester.pump(const Duration(seconds: 5));
      blocker = null;

      // Cancelled: nothing merges. The confirm says how it merges.
      await tester.tap(find.byKey(const ValueKey('board.pr.merge.a')));
      await tester.pumpAndSettle();
      expect(find.text('Merge pull request #12?'), findsOneWidget);
      expect(find.textContaining('squash and merge'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(merges, isEmpty);

      // Confirmed: one merge, and a second click while it runs does nothing.
      await tester.tap(find.byKey(const ValueKey('board.pr.merge.a')));
      await tester.pumpAndSettle();
      // The dialog's Merge (the chip's own sits under the dialog).
      await tester.tap(find.text('Merge').last);
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pump(const Duration(milliseconds: 10));
      await tester.tap(find.byKey(const ValueKey('board.pr.merge.a')), warnIfMissed: false);
      await tester.pump();
      expect(merges, [(12, PrMergeMethod.squash)]);
      mergeGate.complete();
      await tester.pump(Duration.zero);
      await tester.pump(Duration.zero);
      // Merged at once, before gh is asked again.
      expect(find.text('Merged'), findsOneWidget);
      expect(find.byKey(const ValueKey('board.pr.merge.a')), findsNothing);
      await tester.pump(const Duration(seconds: 5));

      await tester.pumpWidget(const SizedBox());
      c.dispose();
      await db.close();
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a finished pull request shows once, on the newest session on its branch, with no Merge', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final db = AppDatabase(NativeDatabase.memory());
      final prefs = await Preferences.load(db);
      final old = _s('old', branch: 'feat/x', day: 1);
      final newest = _s('new', branch: 'feat/x', day: 3);
      final open = _s('open', branch: 'feat/y', day: 1);
      final openLater = _s('open2', branch: 'feat/y', day: 2);
      prefs['code.sessions'] = jsonEncode([
        for (final s in [old, newest, open, openLater]) s.toJson(),
      ]);
      // A merged one that GitHub still calls mergeable: no action is offered on it.
      const merged = PrStatus(number: 2, url: 'u', state: PrState.merged, checks: PrChecks.passing, mergeable: true);
      const stillOpen = PrStatus(number: 3, url: 'u', state: PrState.open, checks: PrChecks.passing);
      final c = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          boardPrSourceProvider.overrideWithValue((
            ready: (_) async => true,
            status: (_, target) async => target == 'feat/x' ? merged : stillOpen,
            method: (_, _) async => PrMergeMethod.squash,
            blocker: (_, _) async => null,
            merge: (_, _, _) async {},
          )),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: LayoutHost(
            language: DesignLanguage.material,
            child: Center(
              child: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final s in [old, newest, open, openLater]) BoardPrChip(info: s, done: true),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(find.byKey(const ValueKey('board.pr.new')), findsOneWidget);
      expect(find.byKey(const ValueKey('board.pr.old')), findsNothing);
      expect(find.text('PR #2'), findsOneWidget);
      expect(find.byKey(const ValueKey('board.pr.merge.new')), findsNothing);
      // An open pull request still shows on every session that may merge it.
      expect(find.text('PR #3'), findsNWidgets(2));

      await tester.pumpWidget(const SizedBox());
      c.dispose();
      await db.close();
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets("a failed ask keeps the chip and waits longer; another pull request's chip doesn't stay up", (
      tester,
    ) async {
      final db = AppDatabase(NativeDatabase.memory());
      final prefs = await Preferences.load(db);
      final session = _s('a', pr: 12);
      prefs['code.sessions'] = jsonEncode([session.toJson()]);
      const pr = PrStatus(number: 12, url: 'u', state: PrState.open, checks: PrChecks.passing, mergeable: true);
      var asks = 0;
      var fail = false;
      final c = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          boardPrSourceProvider.overrideWithValue((
            ready: (_) async => true,
            status: (_, _) async {
              asks++;
              if (fail) throw const GitError("Couldn't ask GitHub: HTTP 502");
              return pr;
            },
            method: (_, _) async => PrMergeMethod.squash,
            blocker: (_, _) async => null,
            merge: (_, _, _) async {},
          )),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: LayoutHost(
            language: DesignLanguage.material,
            // Not Done: no Merge, even for a pull request GitHub would merge.
            child: Center(
              child: SizedBox(width: 420, child: BoardPrChip(info: session, done: false)),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(find.text('PR #12'), findsOneWidget);
      expect(find.byKey(const ValueKey('board.pr.merge.a')), findsNothing);
      expect(asks, 1);

      fail = true;
      await tester.pump(const Duration(minutes: 1, seconds: 1));
      expect(asks, 2);
      // The failure keeps what showed.
      expect(find.text('PR #12'), findsOneWidget);
      // The next ask waits longer than a minute after a second failure (two minutes).
      await tester.pump(const Duration(minutes: 1, seconds: 1));
      expect(asks, 3);
      await tester.pump(const Duration(minutes: 1, seconds: 1));
      expect(asks, 3);
      await tester.pump(const Duration(minutes: 1));
      expect(asks, 4);

      // The session's pull request changes: the old chip goes until the new one is asked about.
      fail = false;
      c.read(codeSessionsProvider.notifier).update(session.copyWith(prNumber: 13));
      await tester.pump();
      expect(c.read(boardPrProvider('a')), isA<PrUnknown>());
      await tester.pump(const Duration(milliseconds: 10));

      await tester.pumpWidget(const SizedBox());
      c.dispose();
      await db.close();
    });
  });
}
