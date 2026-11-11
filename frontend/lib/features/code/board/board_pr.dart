import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../code_providers.dart' show codeSessionsProvider, isDemoPath;
import '../domain/code_session.dart';
import '../git/git_service.dart';

/// What the Board asks GitHub through, so tests can stand in for gh.
typedef BoardPrSource = ({
  Future<bool> Function(String dir) ready,
  Future<PrStatus?> Function(String dir, String target) status,
  Future<void> Function(String dir, int number) merge,
});

final boardPrSourceProvider = Provider<BoardPrSource>(
  (ref) => (ready: GitService.ghReady, status: GitService.prStatus, merge: GitService.mergePr),
);

/// The pull request a session's card looks for: the one EveryAI opened for it, else its own worktree's branch, else
/// the branch it works on in place when that isn't the default one. Null for none (and for demo sessions).
String? prTarget(CodeSessionInfo s) {
  if (isDemoPath(s.workingDir)) return null;
  if (s.prNumber case final n?) return '$n';
  if (s.worktree case final w?) return w.branch.isEmpty ? null : w.branch;
  return const {'', 'main', 'master', 'trunk', 'develop'}.contains(s.branch) ? null : s.branch;
}

/// A card's pull request, as far as the Board knows:
///
/// ```text
///   unknown ──gh answers──► shown(pr) ──later polls──► shown(pr')
///      └──no gh, no remote or no pull request──► none ──a later poll finds one──► shown
/// ```
sealed class BoardPrState {
  const BoardPrState();
}

final class PrUnknown extends BoardPrState {
  const PrUnknown();
}

final class PrNone extends BoardPrState {
  const PrNone();
}

final class PrShown extends BoardPrState {
  const PrShown(this.pr);
  final PrStatus pr;
}

/// How long the Board waits before asking again: a minute while a pull request shows (checks move), five without
/// one; after a failed ask the wait doubles, up to ten minutes.
Duration prPollDelay({required bool found, required int failures}) {
  if (failures > 0) return Duration(seconds: (60 << (failures - 1).clamp(0, 4)).clamp(60, 600));
  return found ? const Duration(minutes: 1) : const Duration(minutes: 5);
}

/// The pull request of session [sessionId]'s card, asked of gh while the card shows (it goes with the card) and at
/// most once a minute. A late answer from an earlier ask is dropped ([_generation]).
final boardPrProvider = NotifierProvider.autoDispose.family<BoardPr, BoardPrState, String>(BoardPr.new);

final class BoardPr extends Notifier<BoardPrState> {
  BoardPr(this.sessionId);

  final String sessionId;
  Timer? _timer;
  int _generation = 0;
  int _failures = 0;
  bool? _ghReady;

  @override
  BoardPrState build() {
    // A new target (a pull request opened from the session) asks again at once.
    final target = ref.watch(
      codeSessionsProvider.select((all) {
        final s = all.where((s) => s.id == sessionId).firstOrNull;
        return s == null ? null : (dir: s.workingDir, target: prTarget(s));
      }),
    );
    ref.onDispose(() {
      _timer?.cancel();
      _generation++;
    });
    _timer?.cancel();
    if (target?.target == null) return const PrNone();
    _schedule(Duration.zero, target!.dir, target.target!);
    return stateOrNull ?? const PrUnknown();
  }

  void _schedule(Duration after, String dir, String target) {
    _timer?.cancel();
    _timer = Timer(after, () => unawaited(_ask(dir, target)));
  }

  Future<void> _ask(String dir, String target) async {
    final gen = ++_generation;
    final source = ref.read(boardPrSourceProvider);
    try {
      _ghReady ??= await source.ready(dir);
      if (!ref.mounted || gen != _generation) return;
      if (_ghReady == false) {
        // No gh or not signed in: nothing to show; look again in ten minutes (the user may sign in).
        state = const PrNone();
        _ghReady = null;
        _schedule(const Duration(minutes: 10), dir, target);
        return;
      }
      final pr = await source.status(dir, target);
      if (!ref.mounted || gen != _generation) return;
      _failures = 0;
      state = pr == null ? const PrNone() : PrShown(pr);
      _schedule(prPollDelay(found: pr != null, failures: 0), dir, target);
    } on Object {
      if (!ref.mounted || gen != _generation) return;
      _failures++;
      _schedule(prPollDelay(found: state is PrShown, failures: _failures), dir, target);
    }
  }

  /// Asks again now (after a merge).
  void refresh() {
    final s = ref.read(codeSessionsProvider).where((s) => s.id == sessionId).firstOrNull;
    final target = s == null ? null : prTarget(s);
    if (s != null && target != null) _schedule(Duration.zero, s.workingDir, target);
  }
}

/// The chip's words: "PR #12", then the checks, the review, and on a Done card whose pull request is open, "Ready to
/// merge" with its line counts.
({String checks, String review, String ready}) prChipText(PrStatus pr, {required bool done}) => (
  checks: switch (pr.checks) {
    PrChecks.passing => 'Checks pass',
    PrChecks.failing => 'Checks fail',
    PrChecks.pending => 'Checks running',
    PrChecks.none => '',
  },
  review: switch (pr.state) {
    PrState.merged => 'Merged',
    PrState.closed => 'Closed',
    PrState.draft => 'Draft',
    PrState.open => switch (pr.review) {
      PrReview.approved => 'Approved',
      PrReview.changesRequested => 'Changes asked',
      PrReview.required => 'Review needed',
      PrReview.none => '',
    },
  },
  ready: done && pr.readyToMerge ? 'Ready to merge +${pr.additions} −${pr.deletions}' : '',
);

/// A merge from the chip, in flight or not (a second click meanwhile does nothing).
enum _Merge { idle, merging }

/// The pull request chip on a Board card: number, checks, review and, when it can merge, Merge (after a confirm that
/// names it). Nothing until gh has answered, and nothing without a pull request.
class BoardPrChip extends ConsumerStatefulWidget {
  const BoardPrChip({super.key, required this.info, required this.done});

  final CodeSessionInfo info;

  /// The card is in Done: an open pull request reads as ready to merge.
  final bool done;

  @override
  ConsumerState<BoardPrChip> createState() => _BoardPrChipState();
}

class _BoardPrChipState extends ConsumerState<BoardPrChip> {
  var _merge = _Merge.idle;

  Future<void> _mergePr(PrStatus pr) async {
    if (_merge != _Merge.idle) return;
    final ok = await showAdaptiveConfirm(
      context,
      title: 'Merge pull request #${pr.number}?',
      message: '"${widget.info.title}" merges into its base branch on GitHub, the way the repository merges.',
      confirmLabel: 'Merge',
    );
    if (!ok || !mounted || _merge != _Merge.idle) return;
    setState(() => _merge = _Merge.merging);
    try {
      await ref.read(boardPrSourceProvider).merge(widget.info.workingDir, pr.number);
      if (mounted) showAdaptiveToast(context, 'Merged #${pr.number}');
    } on Object catch (e) {
      if (mounted) showAdaptiveToast(context, '$e');
    } finally {
      if (mounted) {
        setState(() => _merge = _Merge.idle);
        ref.read(boardPrProvider(widget.info.id).notifier).refresh();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(boardPrProvider(widget.info.id));
    if (state is! PrShown) return const SizedBox.shrink();
    final pr = state.pr;
    final theme = EveryTheme.of(context);
    final text = prChipText(pr, done: widget.done);
    final checksColor = switch (pr.checks) {
      PrChecks.passing => theme.success,
      PrChecks.failing => theme.danger,
      _ => theme.textMuted,
    };
    final quiet = theme.type.caption.tint(theme.textMuted);
    return Padding(
      key: ValueKey('board.pr.${widget.info.id}'),
      padding: const EdgeInsets.only(left: 36, top: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: theme.text.withValues(alpha: 0.05),
              border: Border.all(color: theme.border),
              borderRadius: BorderRadius.circular(99),
            ),
            child: Text('PR #${pr.number}', style: theme.type.caption.mono.tint(theme.text)),
          ),
          if (text.checks.isNotEmpty) Text(text.checks, style: theme.type.caption.tint(checksColor)),
          if (text.review.isNotEmpty) Text(text.review, style: quiet),
          if (text.ready.isNotEmpty)
            Text(text.ready, key: ValueKey('board.pr.ready.${widget.info.id}'), style: quiet.mono),
          if (pr.readyToMerge)
            KitButton(
              key: ValueKey('board.pr.merge.${widget.info.id}'),
              label: 'Merge',
              style: KitButtonStyle.soft,
              busy: _merge == _Merge.merging,
              onPressed: _merge == _Merge.idle ? () => _mergePr(pr) : null,
            ),
        ],
      ),
    );
  }
}
