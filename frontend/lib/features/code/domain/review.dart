import '../git/git_models.dart';

/// The most diff text put in a prompt; past it the files are listed and the
/// model reads the rest itself.
const maxPromptDiff = 40000;

/// [files] as one unified diff, cut at [maxChars]; `cut` says whether it was.
({String text, bool cut}) renderDiff(List<FileDiff> files, {int maxChars = maxPromptDiff}) {
  final out = StringBuffer();
  for (final f in files) {
    final patch = [
      ...f.header,
      for (final h in f.hunks) ...[h.header, ...h.lines],
    ].join('\n');
    if (out.length + patch.length + 1 > maxChars) {
      final room = maxChars - out.length;
      if (room > 200) out.write('${patch.substring(0, room - 1)}\n');
      return (text: out.toString(), cut: true);
    }
    out.write('$patch\n');
  }
  return (text: out.toString(), cut: false);
}

/// A one-line summary: "3 files, +40 −12".
String diffStat(List<FileDiff> files) {
  final added = files.fold(0, (n, f) => n + f.added);
  final removed = files.fold(0, (n, f) => n + f.removed);
  return '${files.length} file${files.length == 1 ? '' : 's'}, +$added −$removed';
}

/// The reviewer subagent's task. With a worktree, [files] are the session's
/// changes since [baseCommit]; without one the reviewer finds them itself.
/// [focus] is what the user asked it to look at.
String reviewBrief({required List<FileDiff> files, String? baseCommit, String focus = ''}) {
  final out = StringBuffer(
    'Review the changes made in this workspace, as a careful senior reviewer would before they are merged. '
    'Read the surrounding code where you need it to judge a change. Do not edit any file.\n\n',
  );
  if (focus.trim().isNotEmpty) out.write('The developer asks you to focus on: ${focus.trim()}\n\n');
  if (baseCommit != null) {
    final diff = renderDiff(files);
    out.write(
      'The changes are everything since commit $baseCommit (run `git diff $baseCommit` to see them again, '
      '`git diff --stat $baseCommit` for an overview). ${diffStat(files)}:\n\n```diff\n${diff.text}```\n',
    );
    if (diff.cut) out.write('The diff above is cut short; read the rest with git diff.\n');
  } else {
    out.write(
      'This workspace has no session branch to compare against. Use `git status` and `git diff` (or `git diff '
      'HEAD`) to find what changed; if it is not a git repository, look at the recently modified files.\n',
    );
  }
  out.write(
    '''

What to look for, most important first:
1. Bugs: wrong logic, unhandled cases and errors, broken edge cases, races, resource leaks.
2. Regressions: behaviour that callers or tests rely on and that changed.
3. Security: injection, unsafe input handling, secrets in code, overly broad permissions.
4. Missing or weak tests for what changed.
Skip style and naming unless it hides a real problem. Do not report something you have not checked in the code.

Your final message is the review. Give each finding as a list item: severity (high, medium or low), the file and line, what is wrong and how it shows up, and the fix in a sentence. Order them by severity. End with a one-line verdict: ready to merge, or what must change first. If you find nothing worth fixing, say so plainly.''',
  );
  return out.toString();
}

/// The message that hands a review to the session's agent.
String reviewFollowUp(String report) =>
    'A reviewer looked over your changes and reported the findings below. Check each one against the code, fix '
    'the ones that hold up, and say which you left alone and why.\n\n<review>\n${report.trim()}\n</review>';
