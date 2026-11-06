// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../code_providers.dart';
import '../git/git_service.dart';
import 'workflow_engine.dart';

/// What the user picks for a finished run's uncommitted work.
enum WorkflowLand { commit, branch, leave }

/// Whether a run that ended this way gets the commit choice: it finished its work (done, or capped with some).
bool workflowAsksLanding(WorkflowRun run) => run.status == WorkflowStatus.done || run.status == WorkflowStatus.capped;

/// The files each run changed in the folder (what differs between the folder when it started and when it ended),
/// by run id. A run that wrote nothing has none, so nothing is asked.
final workflowOwnPathsProvider = NotifierProvider.family<WorkflowOwnPaths, Map<String, List<String>>, String>(
  WorkflowOwnPaths.new,
);

final class WorkflowOwnPaths extends Notifier<Map<String, List<String>>> {
  WorkflowOwnPaths(this.sessionId);
  final String sessionId;

  @override
  Map<String, List<String>> build() => const {};

  void set(String runId, List<String> paths) => state = {...state, runId: paths};
}

/// The lanes whose work merged into the folder, by run id, in the order they merged: landing a run on a branch
/// replays their own commits there (see `GitService.landWithCommits`). Held for this app run only; after a restart
/// a run's lanes land as files in the one commit.
final workflowLanesProvider = NotifierProvider.family<WorkflowLanes, Map<String, List<LaneRef>>, String>(
  WorkflowLanes.new,
);

final class WorkflowLanes extends Notifier<Map<String, List<LaneRef>>> {
  WorkflowLanes(this.sessionId);
  final String sessionId;

  @override
  Map<String, List<LaneRef>> build() => const {};

  void add(String runId, LaneRef lane) => state = {
    ...state,
    runId: [...?state[runId], lane],
  };
}

/// Whether run [runId]'s files are waiting in the session's folder uncommitted. A folder outside git, a run
/// that changed nothing, or a clean folder is false (nothing to ask).
final workflowDirtyProvider = FutureProvider.autoDispose.family<bool, ({String sessionId, String runId})>((
  ref,
  key,
) async {
  final target = ref.read(codeSessionsProvider.notifier).byId(key.sessionId)?.diffTarget;
  final paths = ref.watch(workflowOwnPathsProvider(key.sessionId))[key.runId];
  if (target == null || paths == null || paths.isEmpty) return false;
  try {
    return await GitService.isDirtyAmong(target, paths);
  } on Object {
    return false;
  }
});

/// The choices made this app run, by run id: the sentence the card shows, and whether it worked (a failed one
/// leaves the buttons up, with its reason).
typedef WorkflowLanded = ({String text, bool ok});

final workflowLandingProvider = NotifierProvider.family<WorkflowLandings, Map<String, WorkflowLanded>, String>(
  WorkflowLandings.new,
);

final class WorkflowLandings extends Notifier<Map<String, WorkflowLanded>> {
  WorkflowLandings(this.sessionId);
  final String sessionId;

  @override
  Map<String, WorkflowLanded> build() => const {};

  void set(String runId, WorkflowLanded landed) => state = {...state, runId: landed};
}

/// The commit message offered for [run]: its name and, when the result has one, the fix in a line.
String workflowCommitMessage(WorkflowRun run) {
  final r = run.result;
  final said = r is Map && r['fix_summary'] is String ? (r['fix_summary'] as String).trim().split('\n').first : '';
  final line = said.isEmpty ? run.name : '${run.name}: $said';
  return line.length <= 72 ? line : '${line.substring(0, 71)}…';
}

/// The branch name offered for [run].
String workflowBranchName(WorkflowRun run) {
  final slug = run.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  final id = run.runId.length > 6 ? run.runId.substring(0, 6) : run.runId;
  return 'everyai/${slug.isEmpty ? 'workflow' : slug}-$id';
}

/// The short note the lead gets once the user has chosen. Plain text in a tag; the branch is the only thing the
/// user typed and it is stripped of what could close the tag. [laneCommits]: the workers' own commits that came
/// over onto the branch before the last one; [notes]: lanes whose commits could not.
String workflowLandingMessage(
  WorkflowRun run,
  WorkflowLand choice, {
  String branch = '',
  String commit = '',
  bool committed = true,
  int laneCommits = 0,
  List<String> notes = const [],
}) {
  String attr(String s) => s.replaceAll(RegExp(r'["<>]'), '');
  String text(String s) => s.replaceAll(RegExp(r'</?workflow-landing\b', caseSensitive: false), '‹workflow-landing');
  final lanes = laneCommits == 0
      ? ''
      : ' The workers\' own $laneCommits ${laneCommits == 1 ? 'commit came' : 'commits came'} over first, with their '
            'messages, and the last commit holds the rest.';
  final what = switch (choice) {
    WorkflowLand.commit when !committed => 'The user chose to commit, but there was nothing left to commit.',
    WorkflowLand.commit => 'The user committed the ${run.name} workflow\'s changes on the current branch.$lanes',
    WorkflowLand.branch =>
      'The user committed the ${run.name} workflow\'s changes on a new branch, ${attr(branch)}, '
          'and the folder is now on that branch.$lanes',
    WorkflowLand.leave => 'The user chose to leave the ${run.name} workflow\'s changes uncommitted.',
  };
  final why = committed && choice != WorkflowLand.leave && notes.isNotEmpty
      ? '\n${[for (final n in notes) '- ${text(n)}'].join('\n')}'
      : '';
  return '<workflow-landing run="${attr(run.runId)}" choice="${choice.name}"'
      '${branch.isEmpty ? '' : ' branch="${attr(branch)}"'}${commit.isEmpty ? '' : ' commit="${attr(commit)}"'}>\n'
      '$what$why\n</workflow-landing>';
}
