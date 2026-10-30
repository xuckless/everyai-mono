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

/// Lines that credit an AI tool, which the commit-msg hook removes:
/// Co-authored-by/Signed-off-by trailers naming one, and "Generated with"
/// lines.
final brandingLine = RegExp(
  r'^\s*(co-authored-by|signed-off-by)\s*:.*(openhands|all-hands|claude|anthropic|everyai|openai|chatgpt|gpt-|copilot|cursor|gemini|codex|\[bot\])'
  r'|generated (with|by) .*(openhands|claude|everyai|copilot|chatgpt|codex|cursor|gemini)'
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
