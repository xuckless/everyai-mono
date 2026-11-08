import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/ui/adaptive.dart';
import '../../code_providers.dart';
import '../../domain/code_session.dart';
import '../../domain/git_requests.dart';
import '../../git/git_service.dart';

/// What the console's git button does next. Commit, Create PR and Merge locally ask the session's agent
/// ([git_requests.dart]); Merge into the base fast-forwards it to the one commit the agent prepared; View PR opens it.
enum GitActionKind { commit, viewPr, createPr, prepareMerge, merge }

/// The git button's action: its kind, label, whether it can run now and, for View PR, the address.
typedef GitAction = ({GitActionKind kind, String label, bool enabled, String? url});

/// The one next step for a session's work, in the order a source control panel offers it: commit what isn't
/// committed, then look at the open pull request, else open one when the branch has a remote, else merge it locally.
/// A merged or closed pull request still shows while the branch has nothing newer ([head] is where it was): its
/// commits stay "ahead" after a squash merge, and another PR for them would be a duplicate. Merging locally takes
/// two presses: the first asks the agent to rebase and squash ([GitActionKind.prepareMerge]); once the branch is
/// one commit on top of [base] ([behind] 0) the button merges it. Nothing left to do is a Commit that can't run.
/// Null (no button) without a worktree: an in-place session commits in the user's own checkout, which EveryAI
/// leaves to them.
GitAction? gitActionFor({
  required bool worktree,
  required bool dirty,
  required int ahead,
  required bool hasRemote,
  int behind = 0,
  String base = 'main',
  BranchPr? pr,
  String head = '',
}) {
  if (!worktree) return null;
  if (dirty) return (kind: GitActionKind.commit, label: 'Commit', enabled: true, url: null);
  if (pr != null && (pr.open || pr.head == head)) {
    return (kind: GitActionKind.viewPr, label: 'View PR #${pr.number}', enabled: true, url: pr.url);
  }
  if (ahead > 0 && hasRemote) return (kind: GitActionKind.createPr, label: 'Create PR', enabled: true, url: null);
  if (ahead == 1 && behind == 0) {
    return (kind: GitActionKind.merge, label: 'Merge into $base', enabled: true, url: null);
  }
  if (ahead > 0) return (kind: GitActionKind.prepareMerge, label: 'Merge locally', enabled: true, url: null);
  return (kind: GitActionKind.commit, label: 'Commit', enabled: false, url: null);
}

/// [gitActionFor] for a session, worked out again whenever its diff refreshes (edits, turn ends, commits, the Refresh
/// button). A dirty tree is Commit at once (`git status`, no remote or gh): while the agent edits, that is every
/// refresh. gh is asked about a pull request only on a clean tree with a remote.
final gitButtonProvider = FutureProvider.autoDispose.family<GitAction?, String>((ref, sessionId) async {
  final w = ref.watch(codeSessionsProvider.select((all) => all.where((s) => s.id == sessionId).firstOrNull?.worktree));
  if (w == null) return null;
  final snapshot = await ref.watch(codeGitProvider(sessionId).future);
  if (await GitService.isDirty(w)) return gitActionFor(worktree: true, dirty: true, ahead: 0, hasRemote: false);
  final remote = await GitService.remoteUrl(w);
  final (pr, head) = remote.isEmpty ? (null, '') : await (GitService.prFor(w), GitService.headCommit(w)).wait;
  return gitActionFor(
    worktree: true,
    dirty: false,
    ahead: snapshot.ahead,
    behind: snapshot.behind,
    base: w.baseBranch,
    hasRemote: remote.isNotEmpty,
    pr: pr,
    head: head,
  );
});

/// The primary git button (the console header and Session info → Changes). Commit, Create PR and Merge locally are
/// requests to the agent (sent as a turn, queued while it works); `/commit` and `/pr` still open drafts the user
/// writes.
class GitButton extends ConsumerWidget {
  const GitButton({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final action = ref.watch(gitButtonProvider(sessionId)).value;
    if (action == null) return const SizedBox.shrink();
    final controller = ref.read(codeSessionProvider(sessionId).notifier);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: AdaptiveButton(
        key: const ValueKey('console.git'),
        label: action.label,
        emphasis: ButtonEmphasis.secondary,
        onPressed: !action.enabled
            ? null
            : switch (action.kind) {
                GitActionKind.commit => () => unawaited(controller.send(commitRequest)),
                GitActionKind.createPr => () => unawaited(controller.send(prRequest(_base(ref)))),
                GitActionKind.viewPr => () => unawaited(launchUrl(Uri.parse(action.url!))),
                GitActionKind.prepareMerge || GitActionKind.merge => () {
                  final info = ref.read(codeSessionsProvider.notifier).byId(sessionId);
                  if (info != null) unawaited(mergeLocally(context, ref, info));
                },
              },
      ),
    );
  }

  String _base(WidgetRef ref) =>
      ref.read(codeSessionsProvider.notifier).byId(sessionId)?.worktree?.baseBranch ?? 'the base branch';
}

/// Merges the session's work into its base branch in the main checkout. While the branch isn't one commit on top
/// of the base, the agent is asked to rebase and squash it (conflicts are resolved in its own worktree, so the
/// user's checkout never holds a half-done merge). Once it is, the user confirms the agent's commit and the base
/// fast-forwards to it; then the worktree can go. Failures are shown, not thrown.
Future<void> mergeLocally(BuildContext context, WidgetRef ref, CodeSessionInfo info) async {
  final w = info.worktree;
  if (w == null) return;
  final controller = ref.read(codeSessionProvider(info.id).notifier);
  Future<void> ask(String request) async {
    if (await controller.send(request) && context.mounted) {
      showAdaptiveToast(context, 'Asked the agent to get the branch ready to merge');
    }
  }

  final git = ref.read(codeGitProvider(info.id).notifier);
  final GitSnapshot snapshot;
  final bool dirty;
  try {
    (snapshot, dirty) = await (ref.read(codeGitProvider(info.id).future), GitService.isDirty(w)).wait;
  } on Object catch (e) {
    if (context.mounted) showAdaptiveToast(context, '$e');
    return;
  }
  if (dirty || snapshot.ahead != 1 || snapshot.behind != 0) return ask(prepareMergeRequest(w.baseBranch));
  // While the agent works its branch can still change under the dialog.
  bool running() => ref.read(codeSessionProvider(info.id)).transcript.running;
  if (running()) {
    if (context.mounted) showAdaptiveToast(context, 'The agent is still working. Merge once it has finished.');
    return;
  }
  final candidate = await GitService.mergeCandidate(w);
  if (!context.mounted) return;
  final go = await showAdaptiveConfirm(
    context,
    title: 'Merge into ${w.baseBranch}?',
    message:
        '${w.baseBranch} in ${w.repoRoot} moves forward to the agent\'s commit "${candidate.subject}" '
        '(${candidate.sha.substring(0, 7)}).',
    confirmLabel: 'Merge',
  );
  if (!go || !context.mounted) return;
  if (running()) {
    showAdaptiveToast(context, 'The agent started working again, so nothing was merged.');
    return;
  }
  try {
    // Exactly the commit the user confirmed, whatever the branch points at by now.
    final sha = await git.fastForwardMerge(candidate.sha);
    if (context.mounted) showAdaptiveToast(context, 'Merged into ${w.baseBranch} as ${sha.substring(0, 7)}');
  } on BaseMoved {
    return ask(baseMovedRequest(w.baseBranch));
  } on Object catch (e) {
    if (context.mounted) showAdaptiveToast(context, '$e');
    return;
  }
  if (!context.mounted) return;
  final remove = await showAdaptiveConfirm(
    context,
    title: 'Remove the worktree?',
    message:
        'The work is on ${w.baseBranch} now. Removing deletes the worktree at ${w.path} and branch ${w.branch}; '
        'cancel to keep it and go on working there.',
    confirmLabel: 'Remove',
  );
  if (!remove || !context.mounted) return;
  try {
    await git.discard();
  } on Object catch (e) {
    if (context.mounted) showAdaptiveToast(context, '$e');
  }
}
