import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Where a session's work lives: its own checkout of the project on its own
/// branch, created from the project's branch at [baseCommit].
@immutable
final class SessionWorktree {
  const SessionWorktree({
    required this.repoRoot,
    required this.path,
    required this.branch,
    required this.baseBranch,
    required this.baseCommit,
  });

  /// The user's main checkout.
  final String repoRoot;
  final String path;

  /// `everyai/<slug>`.
  final String branch;

  /// The branch the session started from (squash merges land there).
  final String baseBranch;
  final String baseCommit;

  String get slug => branch.split('/').last;

  factory SessionWorktree.fromJson(Map<String, Object?> json) => SessionWorktree(
    repoRoot: json['repo_root']! as String,
    path: json['path']! as String,
    branch: json['branch']! as String,
    baseBranch: json['base_branch'] as String? ?? '',
    baseCommit: json['base_commit'] as String? ?? '',
  );

  Map<String, Object?> toJson() => {
    'repo_root': repoRoot,
    'path': path,
    'branch': branch,
    'base_branch': baseBranch,
    'base_commit': baseCommit,
  };
}

/// Where an in-place session started: the user's own checkout, its branch and
/// commit, and a snapshot of the working tree (untracked files included) so
/// Changes shows only what the session did, not edits that were already there.
@immutable
final class GitBaseline {
  const GitBaseline({
    required this.repoRoot,
    required this.dir,
    required this.branch,
    required this.commit,
    required this.tree,
  });

  final String repoRoot;

  /// The folder the session works in (the project, maybe below the root).
  final String dir;
  final String branch;
  final String commit;
  final String tree;

  /// A read-only view for diffing and reverting hunks against the snapshot.
  /// Never pass it to anything that commits, merges or removes worktrees.
  SessionWorktree get diffView =>
      SessionWorktree(repoRoot: repoRoot, path: dir, branch: branch, baseBranch: branch, baseCommit: tree);

  factory GitBaseline.fromJson(Map<String, Object?> json) => GitBaseline(
    repoRoot: json['repo_root']! as String,
    dir: json['dir']! as String,
    branch: json['branch'] as String? ?? '',
    commit: json['commit'] as String? ?? '',
    tree: json['tree']! as String,
  );

  Map<String, Object?> toJson() => {
    'repo_root': repoRoot,
    'dir': dir,
    'branch': branch,
    'commit': commit,
    'tree': tree,
  };
}

/// What happened to a file since the session's base commit.
enum ChangeKind {
  added('A'),
  modified('M'),
  deleted('D'),
  renamed('R');

  const ChangeKind(this.letter);
  final String letter;
}

@immutable
final class FileChange {
  const FileChange(this.path, this.kind, {this.added = 0, this.removed = 0});
  final String path;
  final ChangeKind kind;
  final int added;
  final int removed;
}

/// One `@@` hunk of a unified diff.
@immutable
final class DiffHunk {
  const DiffHunk({required this.header, required this.oldStart, required this.newStart, required this.lines});

  /// The `@@ -a,b +c,d @@ context` line.
  final String header;
  final int oldStart;
  final int newStart;

  /// Lines with their ' ', '+' or '-' prefix (and `\ No newline` markers).
  final List<String> lines;

  int get added => lines.where((l) => l.startsWith('+')).length;
  int get removed => lines.where((l) => l.startsWith('-')).length;
}

/// The diff of one file: its `diff --git` header lines and hunks.
@immutable
final class FileDiff {
  const FileDiff({required this.path, required this.header, required this.hunks, this.binary = false});

  final String path;

  /// Everything before the first hunk (`diff --git`, index, ---/+++ lines).
  final List<String> header;
  final List<DiffHunk> hunks;
  final bool binary;

  ChangeKind get kind => header.any((l) => l.startsWith('new file mode'))
      ? ChangeKind.added
      : header.any((l) => l.startsWith('deleted file mode'))
      ? ChangeKind.deleted
      : header.any((l) => l.startsWith('rename from'))
      ? ChangeKind.renamed
      : ChangeKind.modified;

  int get added => hunks.fold(0, (n, h) => n + h.added);
  int get removed => hunks.fold(0, (n, h) => n + h.removed);

  /// A patch with only hunk [i], for `git apply`.
  String patchFor(int i) => '${[...header, hunks[i].header, ...hunks[i].lines].join('\n')}\n';
}

final _hunkHeader = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@');

/// Splits `git diff` output into per-file diffs.
List<FileDiff> parseUnifiedDiff(String diff) {
  final files = <FileDiff>[];
  List<String>? header;
  var hunks = <DiffHunk>[];
  String? hunkHeader;
  var oldStart = 0, newStart = 0;
  var lines = <String>[];
  var path = '';
  var binary = false;

  void endHunk() {
    if (hunkHeader != null) {
      hunks.add(DiffHunk(header: hunkHeader!, oldStart: oldStart, newStart: newStart, lines: lines));
    }
    hunkHeader = null;
    lines = <String>[];
  }

  void endFile() {
    endHunk();
    if (header != null) files.add(FileDiff(path: path, header: header!, hunks: hunks, binary: binary));
    header = null;
    hunks = <DiffHunk>[];
    binary = false;
  }

  for (final line in diff.split('\n')) {
    if (line.startsWith('diff --git ')) {
      endFile();
      header = [line];
      // "diff --git a/x b/x": the b/ side is the current path.
      final b = line.lastIndexOf(' b/');
      path = b >= 0 ? line.substring(b + 3) : line;
      continue;
    }
    if (header == null) continue;
    final m = _hunkHeader.firstMatch(line);
    if (m != null) {
      endHunk();
      hunkHeader = line;
      oldStart = int.parse(m.group(1)!);
      newStart = int.parse(m.group(2)!);
      continue;
    }
    if (hunkHeader != null) {
      if (line.isEmpty) continue;
      lines.add(line);
    } else {
      if (line.startsWith('Binary files ')) binary = true;
      if (line.startsWith('+++ ') && !line.startsWith('+++ /dev/null')) {
        path = line.substring(4).replaceFirst(RegExp(r'^b/'), '');
      }
      header!.add(line);
    }
  }
  endFile();
  return files;
}

/// A branch-safe slug for a session: a few words of its title and a short id.
String sessionSlug(String title, String id) {
  final words = title
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim()
      .split(' ')
      .where((w) => w.isNotEmpty)
      .take(5)
      .join('-');
  final short = id.replaceAll('-', '');
  final tail = short.substring(short.length - 6);
  return words.isEmpty ? tail : '${words.length > 40 ? words.substring(0, 40) : words}-$tail';
}

/// Lines that credit an AI tool, which the commit-msg hook removes (and
/// landing a workflow's lane commits, see `landWithCommits`):
/// Co-authored-by/Signed-off-by/Assisted-by trailers naming one, "Generated
/// with" lines, and session trailers or links (`Claude-Session:`,
/// `claude.ai/code/session_…`). Owner: commits and PRs carry no AI identifiers.
final brandingLine = RegExp(
  r'^\s*(co-authored-by|signed-off-by|assisted-by)\s*:.*(openhands|all-hands|claude|anthropic|everyai|openai|chatgpt|gpt-|copilot|cursor|gemini|codex|opencode|\[bot\])'
  r'|generated (with|by) .*(openhands|claude|everyai|copilot|chatgpt|codex|cursor|gemini|opencode)'
  r'|^\s*claude-session\s*:|claude\.ai/code/session'
  '|🤖',
  caseSensitive: false,
);

/// [message] without AI-credit lines, and without the blank lines they leave
/// at the end.
String stripBranding(String message) {
  final kept = [
    for (final l in message.split('\n'))
      if (!brandingLine.hasMatch(l)) l,
  ];
  while (kept.isNotEmpty && kept.last.trim().isEmpty) {
    kept.removeLast();
  }
  return '${kept.join('\n')}\n';
}

/// A fork's own copy of its parent's folder: a detached worktree at [root],
/// made from a snapshot ([base]) of the parent's working tree, uncommitted
/// and untracked files included. [path] is the parent's folder inside it.
/// A fork worktree no session holds any more (the app quit mid-run, or its session went): where it is, its
/// repository ('' when git no longer knows it), and whether it holds work of its own.
typedef OrphanFork = ({String path, String repoRoot, bool unsaved});

@immutable
final class ForkCopy {
  const ForkCopy({
    required this.repoRoot,
    required this.root,
    required this.path,
    required this.base,
    this.links = const [],
  });

  /// The parent's repository (where the changes are merged back).
  final String repoRoot;
  final String root;
  final String path;
  final String base;

  /// Dependency folders linked in from the parent (node_modules, .venv):
  /// never committed or merged.
  final List<String> links;

  Map<String, Object?> toJson() => {'repo_root': repoRoot, 'root': root, 'path': path, 'base': base, 'links': links};

  static ForkCopy? fromJson(Object? j) => switch (j) {
    {'repo_root': final String r, 'root': final String root, 'path': final String p, 'base': final String b} =>
      ForkCopy(
        repoRoot: r,
        root: root,
        path: p,
        base: b,
        links: [for (final l in j['links'] as List<Object?>? ?? const []) '$l'],
      ),
    _ => null,
  };
}

/// What merging a fork back did: files brought over cleanly, files where
/// both sides changed the same lines (left with conflict markers, or the
/// parent's version kept when they can't be merged as text), and the ref
/// that keeps the fork's work either way.
typedef ForkMerge = ({List<String> merged, List<String> conflicts, String ref});

/// A workflow lane whose work merged into the folder: its fork's ref (the tip it left), the snapshot it started
/// from, and its name for notes. Its own commits are `base..ref`.
typedef LaneRef = ({String ref, String base, String label});

/// What landing a workflow with its lanes' commits did: the new [head] (null when nothing was committed), how many
/// lane commits were replayed, and a note per lane whose commits could not be (its changes are in the last commit).
typedef LaneLanding = ({String? head, int laneCommits, List<String> notes});

/// A branch's latest pull request: still [open], or merged or closed, and the commit it was opened (or merged) at.
typedef BranchPr = ({int number, String url, bool open, String head});

/// A pull request's checks, all together: none reported, still running, all passed, or one failed.
enum PrChecks { none, pending, passing, failing }

/// What reviewers decided: nothing asked, a review still needed, approved, or changes asked for.
enum PrReview { none, required, approved, changesRequested }

/// Where a pull request is: open (a draft or not), merged, or closed without merging.
enum PrState { open, draft, merged, closed }

/// A pull request as the Board's chip shows it (`gh pr view --json` with [prStatusFields]).
@immutable
final class PrStatus {
  const PrStatus({
    required this.number,
    required this.url,
    required this.state,
    this.checks = PrChecks.none,
    this.review = PrReview.none,
    this.mergeable = false,
    this.mergeState = '',
    this.head = '',
    this.additions = 0,
    this.deletions = 0,
  });

  final int number;
  final String url;
  final PrState state;
  final PrChecks checks;
  final PrReview review;

  /// GitHub says it merges without conflicts (`mergeable: MERGEABLE`).
  final bool mergeable;

  /// GitHub's `mergeStateStatus` (CLEAN, BLOCKED, BEHIND, UNSTABLE, HAS_HOOKS, DIRTY, ...); '' when gh didn't say.
  final String mergeState;

  /// The commit the pull request's branch is at on GitHub (`headRefOid`); a merge is tied to it.
  final String head;
  final int additions;
  final int deletions;

  bool get open => state == PrState.open || state == PrState.draft;

  /// The `owner/repo` the pull request is in, from its URL; '' for a URL that isn't GitHub's shape.
  String get repo => RegExp(r'^https?://[^/]+/([^/]+/[^/]+)/pull/\d+').firstMatch(url)?.group(1) ?? '';

  /// GitHub would merge it now: open, not a draft, no conflicts, checks passed (or none), no review still needed or
  /// changes asked for, and, when gh reports it, a merge state of CLEAN or HAS_HOOKS (not blocked by branch
  /// protection, behind its base, or unstable).
  bool get readyToMerge =>
      state == PrState.open &&
      mergeable &&
      (checks == PrChecks.passing || checks == PrChecks.none) &&
      (review == PrReview.none || review == PrReview.approved) &&
      (mergeState.isEmpty || mergeState == 'CLEAN' || mergeState == 'HAS_HOOKS');

  PrStatus withState(PrState next) => PrStatus(
    number: number,
    url: url,
    state: next,
    checks: checks,
    review: review,
    mergeable: mergeable,
    mergeState: mergeState,
    head: head,
    additions: additions,
    deletions: deletions,
  );

  @override
  bool operator ==(Object other) =>
      other is PrStatus &&
      other.number == number &&
      other.url == url &&
      other.state == state &&
      other.checks == checks &&
      other.review == review &&
      other.mergeable == mergeable &&
      other.mergeState == mergeState &&
      other.head == head &&
      other.additions == additions &&
      other.deletions == deletions;

  @override
  int get hashCode =>
      Object.hash(number, url, state, checks, review, mergeable, mergeState, head, additions, deletions);
}

/// The fields [parsePrStatus] reads.
const prStatusFields =
    'number,url,state,isDraft,mergeable,mergeStateStatus,headRefOid,reviewDecision,statusCheckRollup,additions,deletions';

/// [PrStatus] from `gh pr view --json` [prStatusFields] output; null for anything else.
PrStatus? parsePrStatus(String stdout) {
  final Object? json;
  try {
    json = jsonDecode(stdout);
  } on FormatException {
    return null;
  }
  if (json case {'number': final int number, 'url': final String url, 'state': final String state}) {
    return PrStatus(
      number: number,
      url: url,
      state: switch (state) {
        'MERGED' => PrState.merged,
        'CLOSED' => PrState.closed,
        _ => json['isDraft'] == true ? PrState.draft : PrState.open,
      },
      checks: prChecksOf(json['statusCheckRollup']),
      review: switch (json['reviewDecision']) {
        'APPROVED' => PrReview.approved,
        'CHANGES_REQUESTED' => PrReview.changesRequested,
        'REVIEW_REQUIRED' => PrReview.required,
        _ => PrReview.none,
      },
      mergeable: json['mergeable'] == 'MERGEABLE',
      mergeState: json['mergeStateStatus'] is String ? json['mergeStateStatus']! as String : '',
      head: json['headRefOid'] is String ? json['headRefOid']! as String : '',
      additions: (json['additions'] as num?)?.toInt() ?? 0,
      deletions: (json['deletions'] as num?)?.toInt() ?? 0,
    );
  }
  return null;
}

/// The checks of a `statusCheckRollup`: check runs (`status`, `conclusion`) and commit statuses (`state`). One
/// failure fails them all; anything still running keeps them pending; skipped and neutral runs count as passed.
PrChecks prChecksOf(Object? rollup) {
  if (rollup is! List || rollup.isEmpty) return PrChecks.none;
  var pending = false;
  for (final c in rollup) {
    if (c is! Map) continue;
    final String result;
    if (c['state'] case final String s) {
      result = s; // A commit status: SUCCESS, FAILURE, ERROR, PENDING, EXPECTED.
    } else if (c['status'] != 'COMPLETED') {
      result = 'PENDING';
    } else {
      result = '${c['conclusion'] ?? ''}';
    }
    switch (result) {
      case 'FAILURE' || 'ERROR' || 'CANCELLED' || 'TIMED_OUT' || 'ACTION_REQUIRED' || 'STARTUP_FAILURE':
        return PrChecks.failing;
      case 'PENDING' || 'EXPECTED' || 'QUEUED' || 'IN_PROGRESS' || '':
        pending = true;
    }
  }
  return pending ? PrChecks.pending : PrChecks.passing;
}

/// How a pull request merges on GitHub.
enum PrMergeMethod {
  squash('--squash', 'Squash and merge'),
  merge('--merge', 'Merge commit'),
  rebase('--rebase', 'Rebase and merge');

  const PrMergeMethod(this.flag, this.label);
  final String flag;
  final String label;
}

/// How the Board merges, from what the pull request's repository allows (`gh repo view`
/// with `--json mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed`): the one allowed, or with several squash, then a merge
/// commit, then rebase (default pending the owner's confirmation). Squash when the output can't be read.
PrMergeMethod prMergeMethodOf(String repoJson) {
  try {
    if (jsonDecode(repoJson) case final Map<String, Object?> r) {
      if (r['squashMergeAllowed'] == true) return PrMergeMethod.squash;
      if (r['mergeCommitAllowed'] == true) return PrMergeMethod.merge;
      if (r['rebaseMergeAllowed'] == true) return PrMergeMethod.rebase;
    }
  } on FormatException {
    // Below.
  }
  return PrMergeMethod.squash;
}

/// Whether gh's error for `gh pr view <target>` says there is no such pull request (rather than a failure to ask).
bool ghSaysNoPr(String stderr) {
  final e = stderr.toLowerCase();
  return e.contains('no pull requests found') ||
      e.contains('no open pull requests') ||
      e.contains('could not resolve to a pullrequest') ||
      e.contains('could not resolve to a pull request');
}

/// The pull request in `gh pr view --json number,url,state,headRefOid` output, whatever its state; null for output
/// that isn't that JSON.
BranchPr? parsePrView(String stdout) {
  try {
    return switch (jsonDecode(stdout)) {
      {
        'number': final int number,
        'url': final String url,
        'state': final String state,
        'headRefOid': final String h,
      } =>
        (number: number, url: url, open: state == 'OPEN', head: h),
      _ => null,
    };
  } on FormatException {
    return null;
  }
}
