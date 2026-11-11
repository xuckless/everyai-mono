import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/preferences.dart';
import '../code_providers.dart' show codeProjectsProvider;
import '../domain/code_session.dart';
import '../harness/harness.dart' show HarnessError;
import 'board_plan.dart';
import 'board_planner.dart';
import 'board_race.dart';

/// What a task's or runner's session is doing, as the Board sees it ([BoardPlans.observe]).
enum SessionOutcome { running, done, failed, gone }

/// The Board's goals (Preferences `code.board.plans`: a handful of goals with up to 8 short tasks each, small enough
/// for Preferences, and read on every Board build). Moves goals and tasks along their diagrams in board_plan.dart.
final boardPlansProvider = NotifierProvider<BoardPlans, List<PlanGoal>>(BoardPlans.new);

final class BoardPlans extends Notifier<List<PlanGoal>> {
  static const key = 'code.board.plans';

  /// Per goal, the split in flight: a reply for an older split (Split pressed again, the goal removed) is dropped.
  final _splits = <String, int>{};
  var _splitGen = 0;

  @override
  List<PlanGoal> build() {
    final raw = ref.read(preferencesProvider)[key];
    if (raw == null) return const [];
    try {
      return [for (final g in jsonDecode(raw) as List<Object?>) ?PlanGoal.fromJson(g)];
    } on Object {
      return const [];
    }
  }

  void _set(List<PlanGoal> goals) {
    final settled = [for (final g in goals) g.copyWith(stage: settleGoal(g))];
    state = settled;
    ref.read(preferencesProvider)[key] = jsonEncode([for (final g in settled) g.toJson()]);
  }

  PlanGoal? goal(String id) => state.where((g) => g.id == id).firstOrNull;

  void _update(String id, PlanGoal Function(PlanGoal g) change) =>
      _set([for (final g in state) g.id == id ? change(g) : g]);

  void _updateTask(String goalId, String taskId, GoalTask Function(GoalTask t) change) =>
      _update(goalId, (g) => g.copyWith(tasks: [for (final t in g.tasks) t.id == taskId ? change(t) : t]));

  /// A new, empty goal for [projectId], planned by [planner]; its id.
  String add({required String projectId, required LeadPick planner}) {
    final id = planId();
    _set([PlanGoal(id: id, projectId: projectId, planner: planner, createdAt: DateTime.now()), ...state]);
    return id;
  }

  void remove(String id) {
    _splits.remove(id);
    _set([
      for (final g in state)
        if (g.id != id) g,
    ]);
  }

  void setText(String id, String text) => _update(id, (g) => g.copyWith(text: text));
  void setProject(String id, String projectId) => _update(id, (g) => g.copyWith(projectId: projectId));
  void setPlanner(String id, LeadPick planner) => _update(id, (g) => g.copyWith(planner: planner));

  /// Asks the goal's planner for tasks. Only from a draft, or a ready goal with nothing delegated; nothing runs
  /// before this. The tasks replace the old drafts; an error or a bad reply leaves the goal a draft with why.
  Future<void> split(String id) async {
    final g = goal(id);
    if (g == null || g.text.trim().isEmpty) return;
    if (g.stage != GoalStage.draft && !(g.stage == GoalStage.ready && g.tasks.every((t) => t.run is TaskDraft))) {
      return;
    }
    final project = ref.read(codeProjectsProvider).where((p) => p.id == g.projectId).firstOrNull;
    if (project == null) {
      _update(id, (g) => g.copyWith(stage: GoalStage.draft, error: 'Pick a project first.'));
      return;
    }
    final gen = _splits[id] = ++_splitGen;
    _update(id, (g) => g.copyWith(stage: GoalStage.splitting, clearError: true));
    final leads = ref.read(plannerLeadsProvider);
    final fallback = ref.read(defaultLeadProvider);
    try {
      final reply = await ref
          .read(boardPlannerProvider)
          .ask(
            g.planner,
            planSplitPrompt(g.text, project: project.name, leads: leads),
            project: project,
            tag: 'plan-$id',
          );
      if (!ref.mounted || _splits[id] != gen) return;
      switch (parsePlanSplit(reply, leads: leads, fallback: fallback, newId: planId)) {
        case SplitTasks(:final tasks):
          _update(id, (g) => g.copyWith(tasks: tasks, stage: GoalStage.ready, clearError: true));
        case SplitRefused(:final why):
          _update(id, (g) => g.copyWith(stage: GoalStage.draft, error: why));
      }
    } on Object catch (e) {
      if (!ref.mounted || _splits[id] != gen) return;
      final why = e is HarnessError ? e.message : '$e';
      _update(id, (g) => g.copyWith(stage: GoalStage.draft, error: why));
    } finally {
      if (_splits[id] == gen) _splits.remove(id);
    }
  }

  // --- Editing tasks (drafts only) ---

  void editTask(String goalId, String taskId, {String? title, String? brief, LeadPick? lead, bool? worktree}) =>
      _updateTask(
        goalId,
        taskId,
        (t) => t.run.editable ? t.copyWith(title: title, brief: brief, lead: lead, worktree: worktree) : t,
      );

  /// Sets what [taskId] waits for; refused (false) when that would make a loop.
  bool setAfter(String goalId, String taskId, List<String> after) {
    final g = goal(goalId);
    if (g == null) return false;
    final next = [for (final t in g.tasks) t.id == taskId && t.run.editable ? t.copyWith(after: after) : t];
    if (dependencyProblem(next) != null) return false;
    _update(goalId, (g) => g.copyWith(tasks: next));
    return true;
  }

  void addTask(String goalId) {
    final g = goal(goalId);
    if (g == null) return;
    _update(
      goalId,
      (g) => g.copyWith(
        tasks: [
          ...g.tasks,
          GoalTask(id: planId(), title: 'New task', lead: g.tasks.lastOrNull?.lead ?? ref.read(defaultLeadProvider)),
        ],
        stage: g.stage == GoalStage.draft ? GoalStage.ready : g.stage,
      ),
    );
  }

  void removeTask(String goalId, String taskId) {
    final t = goal(goalId)?.task(taskId);
    if (t == null || !t.run.editable) return;
    _update(goalId, (g) => g.copyWith(tasks: withoutTask(g.tasks, taskId)));
  }

  void reorder(String goalId, int from, int to) =>
      _update(goalId, (g) => g.copyWith(tasks: reorderTasks(g.tasks, from, to)));

  // --- Running ---

  /// Queues [taskId] (or every draft task of the goal when null) to start once what it waits for is done, and starts
  /// what can start now. Refused (with why) when the tasks' dependencies loop or point nowhere.
  String? delegate(String goalId, {String? taskId}) {
    final g = goal(goalId);
    if (g == null || g.stage == GoalStage.cancelled) return null;
    if (dependencyProblem(g.tasks) case final why?) return why;
    // A task waits for drafts it depends on: delegating one task queues those too, so it can ever start.
    final queue = <String>{};
    void need(String id) {
      final t = g.task(id);
      if (t == null || t.run is! TaskDraft || !queue.add(id)) return;
      t.after.forEach(need);
    }

    if (taskId == null) {
      for (final t in g.tasks) {
        need(t.id);
      }
    } else {
      need(taskId);
    }
    if (queue.isEmpty) return null;
    _update(
      goalId,
      (g) =>
          g.copyWith(tasks: [for (final t in g.tasks) queue.contains(t.id) ? t.copyWith(run: const TaskQueued()) : t]),
    );
    _advance();
    return null;
  }

  /// The tasks being started now (one start each).
  final _starting = <String>{};

  /// Starts every queued task whose dependencies are done.
  void _advance() {
    for (final g in state) {
      for (final t in tasksToStart(g)) {
        if (!_starting.add(t.id)) continue;
        unawaited(_start(g.id, t.id));
      }
    }
  }

  Future<void> _start(String goalId, String taskId) async {
    final g = goal(goalId);
    final t = g?.task(taskId);
    final project = g == null ? null : ref.read(codeProjectsProvider).where((p) => p.id == g.projectId).firstOrNull;
    if (g == null || t == null || t.run is! TaskQueued) {
      _starting.remove(taskId);
      return;
    }
    _updateTask(goalId, taskId, (t) => t.copyWith(run: const TaskStarting()));
    try {
      if (project == null) throw const HarnessError("The goal's project is gone.");
      final session = await ref
          .read(boardStarterProvider)
          .start(project: project, prompt: planTaskPrompt(g, t), lead: t.lead, worktree: t.worktree);
      if (!ref.mounted) return;
      // Cancelled meanwhile: the session started anyway, so it is kept on the task (the user can stop it).
      _updateTask(
        goalId,
        taskId,
        (t) => t.run is TaskCancelled
            ? t.copyWith(run: TaskCancelled(sessionId: session))
            : t.copyWith(run: TaskStarted(session)),
      );
    } on Object catch (e) {
      if (!ref.mounted) return;
      final why = e is HarnessError ? e.message : '$e';
      _updateTask(goalId, taskId, (t) => t.run is TaskStarting ? t.copyWith(run: TaskFailed(why)) : t);
    } finally {
      _starting.remove(taskId);
    }
    if (ref.mounted) _advance();
  }

  /// What the Board sees of the started tasks' sessions ([outcomes] by session id; a session missing from it is left
  /// alone): finished ones mark their task done or failed, which may start the tasks waiting on them.
  void observe(Map<String, SessionOutcome> outcomes) {
    var changed = false;
    final next = [
      for (final g in state)
        g.copyWith(
          tasks: [
            for (final t in g.tasks)
              switch ((t.run, outcomes[sessionOfRun(t.run)])) {
                (TaskStarted(:final sessionId), SessionOutcome.done) => () {
                  changed = true;
                  return t.copyWith(run: TaskDone(sessionId));
                }(),
                (TaskStarted(:final sessionId), SessionOutcome.failed) => () {
                  changed = true;
                  return t.copyWith(run: TaskFailed('Its session failed.', sessionId: sessionId));
                }(),
                (TaskStarted(:final sessionId), SessionOutcome.gone) => () {
                  changed = true;
                  return t.copyWith(run: TaskFailed('Its session was deleted.', sessionId: sessionId));
                }(),
                _ => t,
              },
          ],
        ),
    ];
    if (!changed) return;
    _set(next);
    _advance();
  }

  /// Stops the goal: drafts and queued tasks are cancelled; started ones are left running unless [stopStarted]
  /// (their session ids, for the caller to stop). The goal is cancelled.
  List<String> cancel(String goalId, {bool stopStarted = false}) {
    final g = goal(goalId);
    if (g == null) return const [];
    final stop = <String>[];
    _update(
      goalId,
      (g) => g.copyWith(
        stage: GoalStage.cancelled,
        tasks: [
          for (final t in g.tasks)
            switch (t.run) {
              TaskDraft() || TaskQueued() || TaskStarting() => t.copyWith(run: const TaskCancelled()),
              TaskStarted(:final sessionId) when stopStarted => () {
                stop.add(sessionId);
                return t.copyWith(run: TaskCancelled(sessionId: sessionId));
              }(),
              _ => t,
            },
        ],
      ),
    );
    return stop;
  }

  /// The goal each started session belongs to: the chip on its Board card.
  Map<String, PlanGoal> get bySession => {
    for (final g in state)
      for (final t in g.tasks) ?sessionOfRun(t.run): g,
  };
}

/// The Board's races (Preferences `code.board.races`). Moves races and runners along their diagrams in
/// board_race.dart.
final boardRacesProvider = NotifierProvider<BoardRaces, List<BoardRace>>(BoardRaces.new);

final class BoardRaces extends Notifier<List<BoardRace>> {
  static const key = 'code.board.races';

  @override
  List<BoardRace> build() {
    final raw = ref.read(preferencesProvider)[key];
    if (raw == null) return const [];
    try {
      return [for (final r in jsonDecode(raw) as List<Object?>) ?BoardRace.fromJson(r)];
    } on Object {
      return const [];
    }
  }

  void _set(List<BoardRace> races) {
    final settled = [for (final r in races) r.copyWith(stage: settleRace(r))];
    state = settled;
    ref.read(preferencesProvider)[key] = jsonEncode([for (final r in settled) r.toJson()]);
  }

  BoardRace? race(String id) => state.where((r) => r.id == id).firstOrNull;

  void _update(String id, BoardRace Function(BoardRace r) change) =>
      _set([for (final r in state) r.id == id ? change(r) : r]);

  /// Starts a race of [prompt] in [project] on each of [leads] (2–4), each in its own worktree; its id.
  String start({required CodeProject project, required String prompt, required List<LeadPick> leads, String? goalId}) {
    final id = planId();
    final now = DateTime.now();
    _set([
      BoardRace(
        id: id,
        projectId: project.id,
        prompt: prompt,
        runners: [for (final l in leads.take(4)) RaceRunner(lead: l, startedAt: now)],
        createdAt: now,
        goalId: goalId,
      ),
      ...state,
    ]);
    for (final (i, l) in leads.take(4).indexed) {
      unawaited(_startRunner(id, i, project, prompt, l));
    }
    return id;
  }

  Future<void> _startRunner(String raceId, int index, CodeProject project, String prompt, LeadPick lead) async {
    RunnerRun run;
    try {
      final session = await ref
          .read(boardStarterProvider)
          .start(project: project, prompt: prompt, lead: lead, worktree: true);
      run = RunnerRunning(session);
    } on Object catch (e) {
      run = RunnerFailed(e is HarnessError ? e.message : '$e');
    }
    if (!ref.mounted) return;
    _update(raceId, (r) {
      final runners = [...r.runners];
      if (index < runners.length && runners[index].run is RunnerStarting) {
        runners[index] = runners[index].copyWith(run: run, startedAt: DateTime.now());
      }
      return r.copyWith(runners: runners);
    });
  }

  /// What the Board sees of the runners' sessions; finished runners record when.
  void observe(Map<String, SessionOutcome> outcomes, {DateTime? now}) {
    var changed = false;
    final at = now ?? DateTime.now();
    final next = [
      for (final r in state)
        r.copyWith(
          runners: [
            for (final x in r.runners)
              switch ((x.run, outcomes[sessionOfRunner(x.run)])) {
                (RunnerRunning(:final sessionId), SessionOutcome.done) => () {
                  changed = true;
                  return x.copyWith(run: RunnerDone(sessionId, at));
                }(),
                (RunnerRunning(:final sessionId), SessionOutcome.failed) => () {
                  changed = true;
                  return x.copyWith(run: RunnerFailed('Its session failed.', sessionId: sessionId));
                }(),
                (RunnerRunning() || RunnerDone(), SessionOutcome.gone) => () {
                  changed = true;
                  return x.copyWith(run: const RunnerDiscarded());
                }(),
                _ => x,
              },
          ],
        ),
    ];
    if (changed) _set(next);
  }

  /// Compare now: the race shows its Compare view even while runners still work.
  void compare(String id) =>
      _update(id, (r) => r.stage == RaceStage.running ? r.copyWith(stage: RaceStage.comparing) : r);

  /// Records the user's pick: [session]'s runner is kept, every other runner discarded. Their worktrees are the
  /// caller's to remove (after the user confirmed).
  void keep(String id, String session) => _update(
    id,
    (r) => r.copyWith(
      stage: RaceStage.kept,
      keptSession: session,
      runners: [
        for (final x in r.runners) sessionOfRunner(x.run) == session ? x : x.copyWith(run: const RunnerDiscarded()),
      ],
    ),
  );

  void cancel(String id) => _update(id, (r) => r.copyWith(stage: RaceStage.cancelled));

  void remove(String id) => _set([
    for (final r in state)
      if (r.id != id) r,
  ]);

  /// The race each runner's session belongs to.
  Map<String, BoardRace> get bySession => {
    for (final r in state)
      for (final x in r.runners) ?sessionOfRunner(x.run): r,
  };
}

/// The Plan lane's width and whether it is folded to a rail (Preferences `code.board.plan_lane`).
typedef PlanLaneLayout = ({double width, bool collapsed});

final boardPlanLaneProvider = NotifierProvider<BoardPlanLane, PlanLaneLayout>(BoardPlanLane.new);

final class BoardPlanLane extends Notifier<PlanLaneLayout> {
  static const key = 'code.board.plan_lane';
  static const defaultWidth = 320.0;
  static const minWidth = 260.0;
  static const maxWidth = 560.0;

  @override
  PlanLaneLayout build() {
    try {
      final json = jsonDecode(ref.read(preferencesProvider)[key] ?? '') as Map<String, Object?>;
      return (
        width: ((json['width'] as num?)?.toDouble() ?? defaultWidth).clamp(minWidth, maxWidth),
        collapsed: json['collapsed'] == true,
      );
    } on Object {
      return (width: defaultWidth, collapsed: false);
    }
  }

  void _save(PlanLaneLayout l) {
    state = l;
    ref.read(preferencesProvider)[key] = jsonEncode({'width': l.width, 'collapsed': l.collapsed});
  }

  /// A new width; [persist] is false while dragging.
  void setWidth(double width, {bool persist = true}) {
    final next = (width: width.clamp(minWidth, maxWidth), collapsed: state.collapsed);
    if (persist) {
      _save(next);
    } else {
      state = next;
    }
  }

  void setCollapsed(bool collapsed) => _save((width: state.width, collapsed: collapsed));
}
