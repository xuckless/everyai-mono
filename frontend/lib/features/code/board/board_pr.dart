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
  Future<PrMergeMethod> Function(String dir, PrStatus pr) method,
  Future<String?> Function(String dir, PrStatus pr) blocker,
  Future<void> Function(String dir, PrStatus pr, PrMergeMethod method) merge,
});

final boardPrSourceProvider = Provider<BoardPrSource>(
  (ref) => (
    ready: GitService.ghReady,
    status: GitService.prStatus,
    method: GitService.prMergeMethod,
    blocker: GitService.prMergeBlocker,
    merge: GitService.mergePr,
  ),
);

/// What every card's gh asks share: one sign-in check (kept ten minutes) and at most [maxCalls] gh processes at once,
/// so a Board of many cards doesn't start two processes per card at the same moment.
final boardGhGateProvider = Provider<BoardGhGate>((ref) => BoardGhGate(ref.watch(boardPrSourceProvider)));

final class BoardGhGate {
  BoardGhGate(this._source, {this.maxCalls = 2});

  final BoardPrSource _source;
  final int maxCalls;
  ({DateTime at, Future<bool> ready})? _ready;
  var _running = 0;
  final _waiting = <Completer<void>>[];

  /// Whether gh is installed and signed in, asked once for every card (again after ten minutes).
  Future<bool> ready(String dir) {
    final r = _ready;
    if (r != null && DateTime.now().difference(r.at) < const Duration(minutes: 10)) return r.ready;
    final ask = _call(() => _source.ready(dir));
    _ready = (at: DateTime.now(), ready: ask);
    return ask;
  }

  final _asking = <String, Future<PrStatus?>>{};

  /// One ask per folder and target at a time: cards on the same branch share the answer.
  Future<PrStatus?> status(String dir, String target) {
    final key = '$dir\x00$target';
    return _asking[key] ??= _call(() => _source.status(dir, target)).whenComplete(() {
      _asking.remove(key);
    });
  }

  /// Runs [job] once fewer than [maxCalls] gh calls are running.
  Future<T> _call<T>(Future<T> Function() job) async {
    while (_running >= maxCalls) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    }
    _running++;
    try {
      return await job();
    } finally {
      _running--;
      if (_waiting.isNotEmpty) _waiting.removeAt(0).complete();
    }
  }
}

/// The pull request a session's card looks for: the one EveryAI opened for it, else its own worktree's branch, else
/// the branch it works on in place when that isn't the default one. Null for none (and for demo sessions).
String? prTarget(CodeSessionInfo s) {
  if (isDemoPath(s.workingDir)) return null;
  if (s.prNumber case final n?) return '$n';
  if (s.worktree case final w?) return w.branch.isEmpty ? null : w.branch;
  return const {'', 'main', 'master', 'trunk', 'develop'}.contains(s.branch) ? null : s.branch;
}

/// A card's pull request, as far as the Board knows, and a merge from it:
///
/// ```text
///   unknown ──gh answers──► shown(pr) ──later polls──► shown(pr')
///      │                       └──Merge──► merging(pr) ──gh merged──► shown(pr merged)
///      │                                       └──blocked, refused or cancelled──► shown(pr)
///      └──no gh, no pull request──► none ──a later poll finds one──► shown
///   (the session's target changes: back to unknown; a failed ask keeps what shows)
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

/// A merge of [pr] is being checked, confirmed or run: a second Merge does nothing, and polls don't replace it.
final class PrMerging extends BoardPrState {
  const PrMerging(this.pr);
  final PrStatus pr;
}

/// How long the Board waits before asking again: a minute while a pull request shows (checks move), five without
/// one; after a failed ask the wait doubles, up to ten minutes.
Duration prPollDelay({required bool found, required int failures}) {
  if (failures > 0) return Duration(seconds: (60 << (failures - 1).clamp(0, 4)).clamp(60, 600));
  return found ? const Duration(minutes: 1) : const Duration(minutes: 5);
}

/// The pull request of session [sessionId]'s card, asked of gh while the card shows (it goes with the card) and at
/// most once a minute; not while the app is hidden. A late answer from an earlier ask is dropped ([_generation]).
final boardPrProvider = NotifierProvider.autoDispose.family<BoardPr, BoardPrState, String>(BoardPr.new);

final class BoardPr extends Notifier<BoardPrState> {
  BoardPr(this.sessionId);

  final String sessionId;
  Timer? _timer;
  int _generation = 0;
  int _failures = 0;

  /// The target the state shown was asked for.
  String? _shownFor;

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
    _generation++;
    if (target?.target == null) return const PrNone();
    _schedule(Duration.zero, target!.dir, target.target!);
    // Another pull request's chip (and its Merge) doesn't stay up while the new one is asked about.
    if (_shownFor != target.target) return const PrUnknown();
    return stateOrNull ?? const PrUnknown();
  }

  void _schedule(Duration after, String dir, String target) {
    _timer?.cancel();
    _timer = Timer(after, () => unawaited(_ask(dir, target)));
  }

  static bool get _appHidden => switch (WidgetsBinding.instance.lifecycleState) {
    AppLifecycleState.hidden || AppLifecycleState.paused || AppLifecycleState.detached => true,
    _ => false,
  };

  Future<void> _ask(String dir, String target) async {
    // Hidden: look again later without asking (and without counting it as a failure).
    if (_appHidden) return _schedule(const Duration(minutes: 1), dir, target);
    final gen = ++_generation;
    final gate = ref.read(boardGhGateProvider);
    try {
      final ready = await gate.ready(dir);
      if (!ref.mounted || gen != _generation) return;
      if (!ready) {
        // No gh or not signed in: nothing to show; look again in ten minutes (the user may sign in).
        _set(const PrNone(), target);
        _schedule(const Duration(minutes: 10), dir, target);
        return;
      }
      final pr = await gate.status(dir, target);
      if (!ref.mounted || gen != _generation) return;
      _failures = 0;
      _set(pr == null ? const PrNone() : PrShown(pr), target);
      _schedule(prPollDelay(found: pr != null, failures: 0), dir, target);
    } on Object {
      // Couldn't ask (network, rate limit, signed out): what shows stays, and the next ask waits longer.
      if (!ref.mounted || gen != _generation) return;
      _failures++;
      _schedule(prPollDelay(found: state is PrShown, failures: _failures), dir, target);
    }
  }

  void _set(BoardPrState next, String target) {
    if (state is PrMerging) return;
    _shownFor = target;
    state = next;
  }

  /// Asks again now (after a merge).
  void refresh() {
    final s = ref.read(codeSessionsProvider).where((s) => s.id == sessionId).firstOrNull;
    final target = s == null ? null : prTarget(s);
    if (s != null && target != null) _schedule(Duration.zero, s.workingDir, target);
  }

  /// Starts a merge of the pull request shown and returns it; null when one is already under way or none shows.
  PrStatus? beginMerge() {
    if (state case PrShown(:final pr)) {
      state = PrMerging(pr);
      return pr;
    }
    return null;
  }

  /// Ends a merge that didn't happen (blocked, refused or cancelled).
  void cancelMerge() {
    if (!ref.mounted) return;
    if (state case PrMerging(:final pr)) state = PrShown(pr);
  }

  /// Merges [pr] with [method] in [dir]; the chip says merged at once, then asks gh again.
  Future<void> merge(String dir, PrStatus pr, PrMergeMethod method) async {
    if (state is! PrMerging) return;
    try {
      await ref.read(boardPrSourceProvider).merge(dir, pr, method);
      if (ref.mounted) state = PrShown(pr.withState(PrState.merged));
    } on Object {
      cancelMerge();
      rethrow;
    } finally {
      if (ref.mounted) refresh();
    }
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

/// The pull request chip on a Board card: number, checks and review; on a Done card (the lead and its work idle)
/// whose pull request GitHub would merge now, Merge: after checking the session's folder holds nothing unpushed, and a
/// confirm that names the pull request and how it merges. Nothing until gh has answered, and nothing without one.
class BoardPrChip extends ConsumerStatefulWidget {
  const BoardPrChip({super.key, required this.info, required this.done});

  final CodeSessionInfo info;

  /// The card is in Done (nothing runs): an open pull request reads as ready to merge, and may merge.
  final bool done;

  @override
  ConsumerState<BoardPrChip> createState() => _BoardPrChipState();
}

class _BoardPrChipState extends ConsumerState<BoardPrChip> {
  Future<void> _mergePr() async {
    // The merge's state lives in the notifier, so a second click (or this chip rebuilt) can't start another.
    final pr = ref.read(boardPrProvider(widget.info.id).notifier);
    final shown = pr.beginMerge();
    if (shown == null) return;
    final source = ref.read(boardPrSourceProvider);
    final dir = widget.info.workingDir;
    try {
      final why = await source.blocker(dir, shown);
      if (why != null) {
        pr.cancelMerge();
        if (mounted) showAdaptiveToast(context, why);
        return;
      }
      final method = await source.method(dir, shown);
      if (!mounted) return pr.cancelMerge();
      final ok = await showAdaptiveConfirm(
        context,
        title: 'Merge pull request #${shown.number}?',
        message:
            '"${widget.info.title}" merges into its base branch on GitHub: ${method.label.toLowerCase()}, at the '
            'commit shown here.',
        confirmLabel: 'Merge',
      );
      if (!ok) return pr.cancelMerge();
      await pr.merge(dir, shown, method);
      if (mounted) showAdaptiveToast(context, 'Merged #${shown.number}');
    } on Object catch (e) {
      pr.cancelMerge();
      if (mounted) showAdaptiveToast(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(boardPrProvider(widget.info.id));
    final (pr, merging) = switch (state) {
      PrShown(:final pr) => (pr, false),
      PrMerging(:final pr) => (pr, true),
      PrUnknown() || PrNone() => (null, false),
    };
    if (pr == null) return const SizedBox.shrink();
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
          // Only once nothing runs: a merge while the agent works could take half-done work.
          if (widget.done && pr.readyToMerge)
            KitButton(
              key: ValueKey('board.pr.merge.${widget.info.id}'),
              label: 'Merge',
              style: KitButtonStyle.soft,
              busy: merging,
              onPressed: merging ? null : _mergePr,
            ),
        ],
      ),
    );
  }
}
