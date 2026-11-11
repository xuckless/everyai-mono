import 'git_models.dart';
import 'repo_check.dart';
import 'git_service_stub.dart' if (dart.library.io) 'git_service_io.dart' as impl;

export 'git_models.dart';
export 'repo_check.dart' show RepoFinding, repoCheckNote, splitRepoCheck;

/// A git or gh command failed; [message] is meant for the user.
final class GitError implements Exception {
  const GitError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A fast-forward merge found the base branch moved on since the session branch was prepared.
final class BaseMoved implements Exception {
  const BaseMoved();
  @override
  String toString() => 'The base branch moved on since this branch was prepared.';
}

/// Session worktrees and what the app does with them, on top of the `git`
/// and `gh` command-line tools. See `git_service_io.dart`.
abstract final class GitService {
  /// The app's data folder (App Support), where worktrees and hooks live.
  static Future<String> dataDir() => impl.dataDir();

  /// The top of the repository [dir] is in, or null outside one.
  static Future<String?> repoRoot(String dir) => impl.repoRoot(dir);

  /// Whether the repository at [repoRoot] has a commit to branch from (a
  /// fresh `git init` has none).
  static Future<bool> hasCommits(String repoRoot) => impl.hasCommits(repoRoot);

  /// What in the project at [dir] can run code by itself (git hooks and config programs, editor tasks, install
  /// scripts, agent CLI plugins), found without running any of it; empty when nothing is.
  static Future<List<RepoFinding>> checkRepo(String dir) => impl.checkRepo(dir);

  /// Every worktree of the repository [dir] is in, the main one included (`git worktree list`); empty outside one.
  static Future<List<String>> worktrees(String dir) => impl.worktrees(dir);

  /// A fork's own worktree, from a snapshot of [dir]'s working tree; null
  /// outside git or with no commit yet (the fork then shares [dir]).
  static Future<ForkCopy?> forkCopy(String dir, {required String worktreesDir, required String slug}) =>
      impl.forkCopy(dir, worktreesDir: worktreesDir, slug: slug);

  /// Commits what the fork did, merges it into the parent's folder file by
  /// file (three-way, against the snapshot) unless [merge] is false, keeps it
  /// under `refs/everyai/forks/<slug>` and removes the worktree.
  static Future<ForkMerge> mergeFork(ForkCopy copy, {required String slug, bool merge = true}) =>
      impl.mergeFork(copy, slug: slug, merge: merge);

  /// Snapshots [dir]'s working tree for an in-place session; null outside git
  /// or in a repository with no commit yet.
  static Future<GitBaseline?> baseline(String dir) => impl.baseline(dir);

  /// A worktree for a new session on `everyai/<slug>`, branched from the main
  /// checkout's current commit (or commit [from]), with EveryAI's commit hooks.
  static Future<SessionWorktree> createWorktree({
    required String repoRoot,
    required String slug,
    required String worktreesDir,
    required String hooksDir,
    String? from,
  }) => impl.createWorktree(repoRoot: repoRoot, slug: slug, worktreesDir: worktreesDir, hooksDir: hooksDir, from: from);

  /// A commit of everything in [w]'s folder now (its uncommitted work too), kept by a ref; [w] is left as it is.
  static Future<String> handoffCommit(SessionWorktree w) => impl.handoffCommit(w);

  /// Files changed since the base commit, committed or not.
  static Future<List<FileChange>> changes(SessionWorktree w) => impl.changes(w);

  /// The whole diff since the base commit, by file.
  static Future<List<FileDiff>> diff(SessionWorktree w) => impl.diff(w);

  /// Undoes one hunk in the working tree.
  /// Changes not committed yet (untracked files included), against HEAD.
  static Future<List<FileDiff>> uncommittedDiff(SessionWorktree w) => impl.uncommittedDiff(w);

  /// Subjects of the commits on the session branch since its base, newest first.
  static Future<List<String>> commitSubjects(SessionWorktree w) => impl.commitSubjects(w);

  /// The `origin` remote's URL, or '' without one.
  static Future<String> remoteUrl(SessionWorktree w) => impl.remoteUrl(w);

  /// Whether anything isn't committed yet (untracked files included); cheaper than [uncommittedDiff].
  static Future<bool> isDirty(SessionWorktree w) => impl.isDirty(w);

  /// The commit the session branch is at.
  static Future<String> headCommit(SessionWorktree w) => impl.headCommit(w);

  /// The session branch's latest pull request (`gh pr view`), open, merged or closed; null without one or gh.
  static Future<BranchPr?> prFor(SessionWorktree w) => impl.prFor(w);

  /// Which of [paths] (relative to [dir]; a folder ends in `/`) git ignores (`git check-ignore`), as given; empty
  /// outside git.
  static Future<Set<String>> ignoredAmong(String dir, List<String> paths) => impl.ignoredAmong(dir, paths);

  /// [target]'s pull request (a number or a branch) as the Board's chip shows it; null when gh says there is none.
  /// Throws [GitError] when it couldn't ask (no gh, the network, a rate limit, signed out, the folder gone).
  static Future<PrStatus?> prStatus(String dir, String target) => impl.prStatus(dir, target);

  /// How [pr] merges, from what its own repository allows ([prMergeMethodOf]).
  static Future<PrMergeMethod> prMergeMethod(String dir, PrStatus pr) => impl.prMergeMethod(dir, pr);

  /// Why [pr] shouldn't merge from the session in [dir] now (uncommitted changes, or the folder isn't at the pull
  /// request's head), or null.
  static Future<String?> prMergeBlocker(String dir, PrStatus pr) => impl.prMergeBlocker(dir, pr);

  /// Merges [pr] with [method], only at the commit it was shown at (`--match-head-commit`); throws [GitError] when
  /// gh refuses.
  static Future<void> mergePr(String dir, PrStatus pr, PrMergeMethod method) => impl.mergePr(dir, pr, method);

  /// Whether the GitHub CLI is installed and signed in.
  static Future<bool> ghReady(String dir) => impl.ghReady(dir);

  static Future<void> revertHunk(SessionWorktree w, FileDiff file, int hunk) => impl.revertHunk(w, file, hunk);

  /// Commits [paths] (everything when null); false when there was nothing to commit.
  static Future<bool> commitAll(SessionWorktree w, String message, {List<String>? paths}) =>
      impl.commitAll(w, message, paths: paths);

  /// Switches to new branch [branch] with the changes and commits [paths] there (everything when null); returns
  /// the commit, or null when there was nothing to commit. Refuses a name git rejects or a branch that exists
  /// before touching anything, and undoes the switch when the commit fails.
  static Future<String?> commitOnNewBranch(SessionWorktree w, String branch, String message, {List<String>? paths}) =>
      impl.commitOnNewBranch(w, branch, message, paths: paths);

  /// Lands a workflow run with its lanes' history: replays each lane's own commits (`base..ref`, in order, with
  /// their authors and messages, AI-credit lines removed) onto the branch, then one commit with [message] for what
  /// the folder holds on [paths] and the paths the lanes touched (the integrate step's work). A lane whose commits
  /// don't apply cleanly is left out of the history, with a note; its changes are in the last commit either way.
  /// The folder is never touched; the branch moves (or new branch [newBranch] is made and checked out), and the
  /// index follows on those paths. [LaneLanding.head] is null when there was nothing to commit.
  static Future<LaneLanding> landWithCommits(
    SessionWorktree w, {
    required List<LaneRef> lanes,
    required List<String> paths,
    required String message,
    String? newBranch,
  }) => impl.landWithCommits(w, lanes: lanes, paths: paths, message: message, newBranch: newBranch);

  /// The tree of everything in the folder now; [changedSince] compares a later state with it.
  static Future<String> snapshotTree(SessionWorktree w) => impl.snapshotTree(w);

  /// The paths that differ between snapshot [tree] and the folder now.
  static Future<List<String>> changedSince(SessionWorktree w, String tree) => impl.changedSince(w, tree);

  /// The paths that differ between trees (or commits) [from] and [to].
  static Future<List<String>> changedBetween(SessionWorktree w, String from, String to) =>
      impl.changedBetween(w, from, to);

  /// Whether any of [paths] has uncommitted changes.
  static Future<bool> isDirtyAmong(SessionWorktree w, List<String> paths) => impl.isDirtyAmong(w, paths);

  /// Snapshots the working tree under `refs/everyai/<slug>/turn-<turn>`.
  static Future<String> checkpoint(SessionWorktree w, int turn) => impl.checkpoint(w, turn);

  /// Puts the working tree back to a [checkpoint].
  static Future<void> restoreCheckpoint(SessionWorktree w, String ref) => impl.restoreCheckpoint(w, ref);

  static Future<({int ahead, int behind})> aheadBehind(SessionWorktree w) => impl.aheadBehind(w);

  /// Fast-forwards the base branch in the main checkout to [sha] (the session's one prepared commit, as the user
  /// confirmed it); [BaseMoved] when the base has moved on since.
  static Future<String> fastForwardMerge(SessionWorktree w, String sha) => impl.fastForwardMerge(w, sha);

  /// The session worktree's newest commit and its subject.
  static Future<({String sha, String subject})> mergeCandidate(SessionWorktree w) => impl.mergeCandidate(w);

  /// What a fork changed in its own worktree since its base.
  static Future<List<FileDiff>> forkDiff(ForkCopy copy) => impl.forkDiff(copy);

  /// The fork worktrees in [forksDir] no session holds ([held]: the roots of those that do).
  static Future<List<OrphanFork>> orphanForks(String forksDir, Set<String> held) => impl.orphanForks(forksDir, held);

  /// Deletes an orphaned fork worktree.
  static Future<void> removeOrphanFork(OrphanFork o) => impl.removeOrphanFork(o);

  static Future<void> push(SessionWorktree w) => impl.push(w);

  /// Opens a pull request with `gh`; returns its URL.
  static Future<String> createPr(SessionWorktree w, {required String title, required String body}) =>
      impl.createPr(w, title: title, body: body);

  /// Deletes the worktree, its branch, checkpoints and hooks.
  static Future<void> removeWorktree(SessionWorktree w, {required String hooksDir, bool deleteBranch = true}) =>
      impl.removeWorktree(w, hooksDir: hooksDir, deleteBranch: deleteBranch);
}
