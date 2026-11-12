import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/features/code/board/board_limits.dart';
import 'package:every_ai/features/code/board/board_pr.dart';
import 'package:every_ai/features/code/board/board_snooze.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/drivers/usage_limit.dart';
import 'package:every_ai/features/code/git/git_service.dart';
import 'package:every_ai/features/code/harness/events.dart';
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
  });
}
