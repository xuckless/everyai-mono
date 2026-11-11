import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show immutable, listEquals;

// The Board's Plan lane: a goal, split into tasks by a planner the user picks, delegated as sessions that start in
// dependency order. Pure data and rules here; the notifier is in board_plan_providers.dart, the lane in
// board_plan_view.dart.

/// A harness and its model ('' its default): the planner of a goal, or the lead a task runs on.
typedef LeadPick = ({String harness, String model});

/// What a task's session is doing, as far as the plan is concerned:
///
/// ```text
///   draft ──Delegate──► queued ──every task it waits for is done──► starting ──started──► started(session)
///     │                   │                                            └──couldn't start──► failed(why)
///     │                   └── a task it waits for failed or was cancelled: stays queued, shown as blocked
///     │                                                     started ──its session finished──► done(session, at)
///     │                                                            └──its session failed──► failed(why, session)
///     └──────────── Cancel plan (draft, queued; started ones only when the user agrees) ──────────► cancelled
///   failed ──Retry──► queued (a new session; the tasks waiting on it start once it is done)
/// ```
///
/// Only [BoardPlans] moves a task; [starting] never outlives the app (a start the app quit during is a failure on
/// the next load, so nothing is started twice).
sealed class TaskRun {
  const TaskRun();

  /// Still editable (nothing started yet).
  bool get editable => this is TaskDraft;
}

final class TaskDraft extends TaskRun {
  const TaskDraft();
}

final class TaskQueued extends TaskRun {
  const TaskQueued();
}

final class TaskStarting extends TaskRun {
  const TaskStarting();
}

final class TaskStarted extends TaskRun {
  const TaskStarted(this.sessionId);
  final String sessionId;
}

final class TaskDone extends TaskRun {
  const TaskDone(this.sessionId, {this.at});
  final String sessionId;

  /// When the plan saw it finish (a task waiting on several starts from the one that finished last).
  final DateTime? at;
}

final class TaskFailed extends TaskRun {
  const TaskFailed(this.why, {this.sessionId});
  final String why;
  final String? sessionId;
}

final class TaskCancelled extends TaskRun {
  const TaskCancelled({this.sessionId});
  final String? sessionId;
}

/// The session a task started, if any.
String? sessionOfRun(TaskRun run) => switch (run) {
  TaskStarted(:final sessionId) || TaskDone(:final sessionId) => sessionId,
  TaskFailed(:final sessionId) || TaskCancelled(:final sessionId) => sessionId,
  TaskDraft() || TaskQueued() || TaskStarting() => null,
};

/// One task of a goal. [after] holds the ids of the tasks it waits for (ids, so reordering keeps them).
@immutable
final class GoalTask {
  const GoalTask({
    required this.id,
    required this.title,
    this.brief = '',
    this.after = const [],
    required this.lead,
    this.worktree = true,
    this.run = const TaskDraft(),
  });

  final String id;
  final String title;
  final String brief;
  final List<String> after;
  final LeadPick lead;

  /// Runs on its own branch in a worktree (the default), or in the project folder itself.
  final bool worktree;
  final TaskRun run;

  GoalTask copyWith({
    String? title,
    String? brief,
    List<String>? after,
    LeadPick? lead,
    bool? worktree,
    TaskRun? run,
  }) => GoalTask(
    id: id,
    title: title ?? this.title,
    brief: brief ?? this.brief,
    after: after ?? this.after,
    lead: lead ?? this.lead,
    worktree: worktree ?? this.worktree,
    run: run ?? this.run,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'brief': brief,
    'after': after,
    'harness': lead.harness,
    'model': lead.model,
    'worktree': worktree,
    'run': _runToJson(run),
  };

  static GoalTask? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final id = json['id'];
    final title = json['title'];
    if (id is! String || title is! String) return null;
    return GoalTask(
      id: id,
      title: title,
      brief: json['brief'] as String? ?? '',
      after: [for (final a in json['after'] as List<Object?>? ?? const []) ?a as String?],
      lead: (harness: json['harness'] as String? ?? '', model: json['model'] as String? ?? ''),
      worktree: json['worktree'] as bool? ?? true,
      run: _runFromJson(json['run']),
    );
  }
}

Map<String, Object?> _runToJson(TaskRun run) => switch (run) {
  TaskDraft() => {'s': 'draft'},
  TaskQueued() => {'s': 'queued'},
  // Never kept as starting: see [_runFromJson].
  TaskStarting() => {'s': 'starting'},
  TaskStarted(:final sessionId) => {'s': 'started', 'session': sessionId},
  TaskDone(:final sessionId, :final at) => {'s': 'done', 'session': sessionId, 'at': ?at?.millisecondsSinceEpoch},
  TaskFailed(:final why, :final sessionId) => {'s': 'failed', 'why': why, 'session': ?sessionId},
  TaskCancelled(:final sessionId) => {'s': 'cancelled', 'session': ?sessionId},
};

TaskRun _runFromJson(Object? json) {
  if (json is! Map<String, Object?>) return const TaskDraft();
  final session = json['session'] as String?;
  return switch (json['s']) {
    'queued' => const TaskQueued(),
    // The app quit while it was starting: maybe it started, maybe not. Failing it starts nothing twice.
    'starting' => const TaskFailed(
      'EveryAI closed while this task was starting. Check for its session, then retry it.',
    ),
    'started' when session != null => TaskStarted(session),
    'done' when session != null => TaskDone(
      session,
      at: switch (json['at']) {
        final num ms => DateTime.fromMillisecondsSinceEpoch(ms.toInt()),
        _ => null,
      },
    ),
    'failed' => TaskFailed(json['why'] as String? ?? 'Failed.', sessionId: session),
    'cancelled' => TaskCancelled(sessionId: session),
    _ => const TaskDraft(),
  };
}

/// Where a goal is:
///
/// ```text
///   draft ──Split──► splitting ──the planner's tasks──► ready ──Delegate──► running ──every task done──► done
///     ▲                  └──error or a bad reply──► draft (with why)              └──a task failed, none run──► failed
///     └──────────── Split again (nothing delegated yet) ───────────┘
///   any ──Cancel plan──► cancelled
/// ```
///
/// [draft], [splitting] and [cancelled] are set by [BoardPlans]; the others follow the tasks ([settleGoal]).
/// [splitting] doesn't outlive the app (back to draft on the next load).
enum GoalStage { draft, splitting, ready, running, done, failed, cancelled }

@immutable
final class PlanGoal {
  const PlanGoal({
    required this.id,
    required this.projectId,
    required this.planner,
    required this.createdAt,
    this.text = '',
    this.tasks = const [],
    this.stage = GoalStage.draft,
    this.error,
    this.mode = defaultDelegateMode,
  });

  final String id;
  final String projectId;
  final String text;

  /// The mode its tasks' sessions start in (an AgentMode name): Auto-edit unless the user picked another.
  final String mode;
  final LeadPick planner;
  final List<GoalTask> tasks;
  final GoalStage stage;

  /// Why the last split didn't give tasks.
  final String? error;
  final DateTime createdAt;

  PlanGoal copyWith({
    String? projectId,
    String? text,
    LeadPick? planner,
    List<GoalTask>? tasks,
    GoalStage? stage,
    String? error,
    bool clearError = false,
    String? mode,
  }) => PlanGoal(
    id: id,
    mode: mode ?? this.mode,
    projectId: projectId ?? this.projectId,
    planner: planner ?? this.planner,
    createdAt: createdAt,
    text: text ?? this.text,
    tasks: tasks ?? this.tasks,
    stage: stage ?? this.stage,
    error: clearError ? null : error ?? this.error,
  );

  GoalTask? task(String id) => tasks.where((t) => t.id == id).firstOrNull;

  /// Tasks finished, of all that aren't cancelled: the goal card's progress bar.
  ({int done, int total}) get progress =>
      (done: tasks.where((t) => t.run is TaskDone).length, total: tasks.where((t) => t.run is! TaskCancelled).length);

  Map<String, Object?> toJson() => {
    'id': id,
    'project': projectId,
    'text': text,
    'planner': {'harness': planner.harness, 'model': planner.model},
    'tasks': [for (final t in tasks) t.toJson()],
    'stage': stage.name,
    'error': ?error,
    'created': createdAt.millisecondsSinceEpoch,
    'mode': mode,
  };

  static PlanGoal? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final id = json['id'];
    final project = json['project'];
    if (id is! String || project is! String) return null;
    final planner = json['planner'] as Map<String, Object?>? ?? const {};
    final stage = GoalStage.values.asNameMap()[json['stage']] ?? GoalStage.draft;
    return PlanGoal(
      id: id,
      projectId: project,
      text: json['text'] as String? ?? '',
      planner: (harness: planner['harness'] as String? ?? '', model: planner['model'] as String? ?? ''),
      tasks: [for (final t in json['tasks'] as List<Object?>? ?? const []) ?GoalTask.fromJson(t)],
      // A split the app quit during gave nothing.
      stage: stage == GoalStage.splitting ? GoalStage.draft : stage,
      error: json['error'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch((json['created'] as num?)?.toInt() ?? 0),
      mode: json['mode'] as String? ?? defaultDelegateMode,
    );
  }
}

/// Delegated tasks run unattended, so Auto-edit by default: edits go ahead, commands still ask.
const defaultDelegateMode = 'autoEdit';

/// The stage [goal]'s tasks put it in: drafts only → ready; any queued, starting or started → running; every
/// remaining task done → done; else (a task failed or the rest were cancelled) → failed. Draft, splitting and
/// cancelled goals keep theirs.
GoalStage settleGoal(PlanGoal goal) {
  switch (goal.stage) {
    case GoalStage.draft || GoalStage.splitting || GoalStage.cancelled:
      return goal.stage;
    case GoalStage.ready || GoalStage.running || GoalStage.done || GoalStage.failed:
  }
  final runs = [for (final t in goal.tasks) t.run];
  if (runs.isEmpty) return GoalStage.ready;
  if (goal.tasks.any((t) => t.run is TaskQueued && !taskBlocked(goal, t)) ||
      runs.any((r) => r is TaskStarting || r is TaskStarted)) {
    return GoalStage.running;
  }
  if (runs.every((r) => r is TaskDraft)) return GoalStage.ready;
  final live = runs.where((r) => r is! TaskCancelled).toList();
  if (live.isNotEmpty && live.every((r) => r is TaskDone)) return GoalStage.done;
  if (runs.any((r) => r is TaskFailed) || runs.any((r) => r is TaskQueued)) return GoalStage.failed;
  // Drafts left beside finished ones: the user delegated part of it.
  return runs.any((r) => r is TaskDraft) ? GoalStage.ready : GoalStage.done;
}

/// Whether [task] waits on a task that failed or was cancelled (it won't start by itself).
bool taskBlocked(PlanGoal goal, GoalTask task) => task.after.any((id) {
  final dep = goal.task(id);
  return dep == null || dep.run is TaskFailed || dep.run is TaskCancelled;
});

/// The queued tasks of [goal] to start now: every task they wait for is done.
List<GoalTask> tasksToStart(PlanGoal goal) => [
  if (goal.stage != GoalStage.cancelled)
    for (final t in goal.tasks)
      if (t.run is TaskQueued && t.after.every((id) => goal.task(id)?.run is TaskDone)) t,
];

/// What's wrong with [tasks]' dependencies: a task waiting on one that isn't there, on itself, or a loop. Null when
/// they can all run.
String? dependencyProblem(List<GoalTask> tasks) {
  final byId = {for (final t in tasks) t.id: t};
  for (final t in tasks) {
    for (final a in t.after) {
      if (a == t.id) return '"${t.title}" waits on itself.';
      if (!byId.containsKey(a)) return '"${t.title}" waits on a task that isn\'t there.';
    }
  }
  // Depth-first: a task met again while its own chain is open is a loop.
  final state = <String, int>{};
  String? loop;
  bool visit(GoalTask t) {
    if (state[t.id] == 2) return false;
    if (state[t.id] == 1) {
      loop = t.title;
      return true;
    }
    state[t.id] = 1;
    for (final a in t.after) {
      if (visit(byId[a]!)) return true;
    }
    state[t.id] = 2;
    return false;
  }

  for (final t in tasks) {
    if (visit(t)) return 'The tasks wait on each other in a loop (through "$loop").';
  }
  return null;
}

/// [tasks] with the one at [from] moved to [to] (ListView's reorder indexes: [to] counts the moved one's old place).
List<GoalTask> reorderTasks(List<GoalTask> tasks, int from, int to) {
  final list = [...tasks];
  final moved = list.removeAt(from);
  list.insert(to > from ? to - 1 : to, moved);
  return list;
}

/// [tasks] without [id], and without it in the others' [GoalTask.after].
List<GoalTask> withoutTask(List<GoalTask> tasks, String id) => [
  for (final t in tasks)
    if (t.id != id) t.after.contains(id) ? t.copyWith(after: [...t.after]..remove(id)) : t,
];

// --- The split ---

/// A harness the planner may hand tasks to: its id, its name and the models it can use (empty: its default only).
typedef PlannerLead = ({String id, String label, List<String> models});

/// What the planner is asked to split [goal] into.
/// Prompt reason: the reply is parsed by [parsePlanSplit], so the shape is spelled out exactly; tasks must be small
/// enough to run unattended in parallel worktrees, and the leads listed are the only ones the app can start.
String planSplitPrompt(String goal, {required String project, required List<PlannerLead> leads}) {
  final list = [
    for (final l in leads)
      '- "${l.id}" (${l.label})${l.models.isEmpty ? '' : ', models: ${l.models.take(12).map((m) => '"$m"').join(', ')}'}',
  ].join('\n');
  return '''
You are planning work for coding agents in the project "$project". Split the goal below into 2 to 8 tasks that
separate agents can each finish on their own, every one on its own git branch. Read the code if that helps you plan,
but don't change anything.

Rules:
- Each task is a self-contained piece of work with a clear finish line (tests pass, the feature works, the doc exists).
- Keep tasks independent where you can, so they run at the same time. When one really needs another's result, list
  it in "after" (1-based numbers of earlier tasks). Never make a loop.
- "brief" tells the agent what to do and how to check it, in 1 to 4 sentences. Don't repeat the goal word for word.
- "harness" is one of the agents below, picked for the job; "model" is one of its listed models, or "" for its default.

Agents:
$list

Reply with JSON only, as the text of your final message (don't present it through a tool), in exactly this shape:
{"tasks":[{"title":"Short imperative title","brief":"What to do and how to check it.","after":[],"harness":"<id>","model":""}]}

Goal:
${goal.trim()}''';
}

/// The planner's reply, read.
sealed class PlanSplit {
  const PlanSplit();
}

final class SplitTasks extends PlanSplit {
  const SplitTasks(this.tasks);
  final List<GoalTask> tasks;
}

final class SplitRefused extends PlanSplit {
  const SplitRefused(this.why);
  final String why;
}

/// The longest brief kept from a planner (they are stored with the goal).
const maxBriefChars = 2000;

/// Reads the planner's [reply] into 2–8 tasks: the last JSON object in it with a "tasks" list (code fences, words
/// and other objects around it, such as a file the planner printed, are skipped), each task with a title, a brief, earlier tasks to wait for (1-based), and a harness from [leads] (else
/// [fallback]) with one of its models (else its default). New ids come from [newId].
PlanSplit parsePlanSplit(
  String reply, {
  required List<PlannerLead> leads,
  required LeadPick fallback,
  required String Function() newId,
}) {
  final json = _planObject(reply);
  if (json == null) return const SplitRefused("The planner's reply had no tasks in it.");
  final raw = json['tasks'];
  if (raw is! List || raw.isEmpty) return const SplitRefused("The planner's reply had no tasks in it.");
  if (raw.length < 2) return const SplitRefused('The planner gave one task; try Split again or add tasks yourself.');
  if (raw.length > 8) return const SplitRefused('The planner gave more than 8 tasks; make the goal smaller.');
  final byId = {for (final l in leads) l.id: l};
  final ids = [for (var i = 0; i < raw.length; i++) newId()];
  final tasks = <GoalTask>[];
  for (final (i, t) in raw.indexed) {
    if (t is! Map<String, Object?>) return SplitRefused('Task ${i + 1} in the reply isn\'t an object.');
    final title = '${t['title']}'.trim();
    if (t['title'] is! String || title.isEmpty) return SplitRefused('Task ${i + 1} has no title.');
    var brief = t['brief'] is String ? (t['brief']! as String).trim() : '';
    if (brief.length > maxBriefChars) brief = '${brief.substring(0, maxBriefChars - 1)}…';
    final after = <String>[];
    for (final a in t['after'] is List ? t['after']! as List : const []) {
      final n = a is num ? a.toInt() : int.tryParse('$a');
      if (n == null || n < 1 || n > raw.length) return SplitRefused('Task ${i + 1} waits on a task that isn\'t there.');
      if (n == i + 1) return SplitRefused('Task ${i + 1} waits on itself.');
      if (!after.contains(ids[n - 1])) after.add(ids[n - 1]);
    }
    final lead = byId[t['harness']];
    final model = t['model'];
    tasks.add(
      GoalTask(
        id: ids[i],
        title: title.length > 120 ? '${title.substring(0, 117)}…' : title,
        brief: brief,
        after: after,
        lead: lead == null
            ? fallback
            : (harness: lead.id, model: model is String && lead.models.contains(model) ? model : ''),
      ),
    );
  }
  if (dependencyProblem(tasks) case final why?) return SplitRefused(why);
  return SplitTasks(tasks);
}

/// The last top-level `{…}` in [text] that decodes as a JSON object with a "tasks" list, or null. One pass over the
/// text finds the top-level objects (quotes count only inside braces, so prose around them can't confuse it).
Map<String, Object?>? _planObject(String text) {
  final spans = <(int, int)>[];
  var depth = 0;
  var start = -1;
  var inString = false;
  var escaped = false;
  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (c == 0x5C) {
        escaped = true;
      } else if (c == 0x22) {
        inString = false;
      }
      continue;
    }
    if (c == 0x22 && depth > 0) {
      inString = true;
    } else if (c == 0x7B) {
      if (depth == 0) start = i;
      depth++;
    } else if (c == 0x7D && depth > 0) {
      depth--;
      if (depth == 0) spans.add((start, i + 1));
    }
  }
  for (final (from, to) in spans.reversed) {
    try {
      final v = jsonDecode(text.substring(from, to));
      if (v is Map<String, Object?> && v['tasks'] is List) return v;
    } on FormatException {
      // Not JSON: an earlier one may be.
    }
  }
  return null;
}

/// What a delegated task's session is told.
/// Prompt reason: the agent starts cold on its own branch; it needs the whole goal for context and its own share of
/// it. A task that waits on others starts from their work (stacked on the one that finished last), so it is told
/// whose work its branch already holds, which other tasks' work to merge in before it starts (by commit, so it
/// can't pick the wrong branch), and which ran in the project folder, whose changes aren't on any branch.
String planTaskPrompt(PlanGoal goal, GoalTask task, {TaskHandoff handoff = noHandoff}) {
  final notes = [
    if (handoff.base case final b?) 'Your branch already holds the work of "${b.title}", which this task builds on.',
    if (handoff.merges.isNotEmpty)
      'Before you start, merge in the work of the other tasks this one waits on: '
          '${handoff.merges.map((m) => '`git merge --no-edit ${m.commit}` ("${m.title}")').join(', ')}. Resolve any '
          'conflicts so both sides keep working.',
    if (handoff.inPlace.isNotEmpty)
      '${handoff.inPlace.map((t) => '"$t"').join(', ')} ran in the project folder itself, so '
          '${handoff.inPlace.length == 1 ? 'its changes are' : 'their changes are'} not on your branch.',
  ];
  return [
    task.title,
    if (task.brief.trim().isNotEmpty) task.brief.trim(),
    'This is one task of a larger goal, split into ${goal.tasks.length} tasks that run as separate sessions. Do only '
        'this task. The goal:\n${goal.text.trim()}',
    ...notes,
  ].join('\n\n');
}

/// The stages and run states as [BoardPlans] persists them, for tests: equal when nothing a user could see differs.
bool samePlans(List<PlanGoal> a, List<PlanGoal> b) =>
    listEquals([for (final g in a) jsonEncode(g.toJson())], [for (final g in b) jsonEncode(g.toJson())]);

/// A short random id for goals and tasks.
String planId([math.Random? random]) {
  final r = random ?? math.Random();
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  return [for (var i = 0; i < 10; i++) chars[r.nextInt(chars.length)]].join();
}

/// What a task's worktree starts from, worked out when it starts: the work of the task it waits on that finished last
/// ([base]: a commit holding that task's work, committed or not), the other finished tasks' work to merge first
/// ([merges]), and tasks that ran in the project folder itself ([inPlace]; their work isn't on any branch).
typedef TaskHandoff = ({
  ({String title, String commit})? base,
  List<({String title, String commit})> merges,
  List<String> inPlace,
});

const TaskHandoff noHandoff = (base: null, merges: [], inPlace: []);

/// The tasks [task] waits on, the one that finished last first (unknown finish times last).
List<GoalTask> depsByFinish(PlanGoal goal, GoalTask task) {
  int at(GoalTask t) => switch (t.run) {
    TaskDone(:final at?) => at.millisecondsSinceEpoch,
    _ => 0,
  };
  return [for (final id in task.after) ?goal.task(id)]..sort((a, b) => at(b).compareTo(at(a)));
}
