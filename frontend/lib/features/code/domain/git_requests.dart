/// What the git buttons ask the session's agent to do. The agent knows the work, so it writes the commit message,
/// the pull request and the merge commit itself, on its own lead (an outside lead spends nothing of EveryAI's).
/// Each goes out as a user turn, queued while the agent is busy.
library;

/// The Commit button.
const commitRequest =
    'Commit the work so far on this branch, with messages in this repository\'s style. Leave out anything that '
    'shouldn\'t be committed (build output, secrets, scratch files). Don\'t push.';

/// The Create PR button: the branch goes to the remote and a pull request opens against [base].
String prRequest(String base) =>
    'Push this branch and open a pull request against $base with the GitHub CLI (gh pr create). Commit anything '
    'left first. Write the title and description in this repository\'s style, saying what changed and why, and '
    'reply with the pull request\'s address.';

/// Merge locally while the branch isn't one commit on top of [base]: the agent rebases (and resolves conflicts in
/// its own worktree, so the user's checkout never holds a half-done merge) and squashes. The app then
/// fast-forwards [base] to that commit when the user presses Merge again.
String prepareMergeRequest(String base) =>
    'Get this branch ready to merge into $base. Commit anything left, rebase onto the latest $base (resolve any '
    'conflicts here, then run the project\'s checks), and squash the branch into one commit whose message '
    'describes the whole change in this repository\'s style. Don\'t merge or push: tell me when it\'s ready, and '
    'I\'ll merge it.';

/// Merge into [base] found the branch no longer sits on it ([base] moved since the agent prepared it).
String baseMovedRequest(String base) =>
    '$base moved since this branch was prepared, so it can\'t be merged as it is. ${prepareMergeRequest(base)}';
