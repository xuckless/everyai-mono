import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/preferences.dart';
import '../code_providers.dart'
    show
        codeProjectsProvider,
        codeSessionProvider,
        codeSessionsProvider,
        codeStatusesProvider,
        openCodeSessionsProvider;
import '../domain/agent_mode.dart';
import '../domain/code_session.dart';
import '../harness/harness.dart' show HarnessError;
import 'board_plan.dart';
import 'board_planner.dart';
import 'board_providers.dart' show childrenByParent;
import 'board_race.dart';
import 'board_state.dart' show runningDescendants;

/// What a task's or runner's session is doing, as the plans see it ([boardPlanWatchProvider]).
enum SessionOutcome { running, done, failed, gone }

/// What happens to the sessions a goal or race already started when the user cancels or removes it.
enum StartedChoice { keepRunning, stop }

/// The Board's goals (Preferences `code.board.plans`: a handful of goals with up to 8 short tasks each, small enough
/// for Preferences). Moves goals and tasks along their diagrams in board_plan.dart. Tasks start in the background
/// wherever the user is ([boardPlanWatchProvider] reports their sessions, app-wide).
final boardPlansProvider = NotifierProvider<BoardPlans, List<PlanGoal>>(BoardPlans.new);

final class BoardPlans extends Notifier<List<PlanGoal>> {
  static const key = 'code.board.plans';

  /// Per goal, the split in flight: a reply for an older split (Split pressed again, the goal removed) is dropped,
  /// and completing [cancel] ends the planner.
  final _splits = <String, ({int gen, Completer<void> cancel})>{};
  var _splitGen = 0;

  @override
  List<PlanGoal> build() {
    final raw = ref.read(preferencesProvider)[key];
    if (raw == null) return const [];
    try {
      // Settled on load: a task that was starting when the app quit came back failed, which may finish its goal.
      final goals = [
        for (final g in jsonDecode(raw) as List<Object?>)
          if (PlanGoal.fromJson(g) case final g?) g.copyWith(stage: settleGoal(g)),
      ];
      // Queued tasks whose dependencies finished while the app was closed start now.
      Future.microtask(() {
        if (ref.mounted) _advance();
      });
      return goals;
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

  BoardStarter get _starter => ref.read(boardStarterProvider);

  /// A new, empty goal for [projectId], planned by [planner]; its id.
  String add({required String projectId, required LeadPick planner}) {
    final id = planId();
    _set([PlanGoal(id: id, projectId: projectId, planner: planner, createdAt: DateTime.now()), ...state]);
    return id;
  }

  /// Whether removing [id] needs the user's word: a split runs, or tasks are queued, starting or started.
  bool busy(String id) {
    final g = goal(id);
    if (g == null) return false;
    return g.stage == GoalStage.splitting ||
        g.tasks.any((t) => t.run is TaskQueued || t.run is TaskStarting || t.run is TaskStarted);
  }

  /// Removes the goal: a split in flight ends, queued tasks never start, and started sessions are stopped with
  /// [started] = [StartedChoice.stop] (else left running, without the goal).
  void remove(String id, {StartedChoice started = StartedChoice.keepRunning}) {
    _endSplit(id);
    if (busy(id)) cancel(id, started: started);
    _set([
      for (final g in state)
        if (g.id != id) g,
    ]);
  }

  void setText(String id, String text) => _update(id, (g) => g.copyWith(text: text));
  void setProject(String id, String projectId) => _update(id, (g) => g.copyWith(projectId: projectId));
  void setPlanner(String id, LeadPick planner) => _update(id, (g) => g.copyWith(planner: planner));

  /// The mode the goal's tasks start in (tasks already started keep theirs).
  void setMode(String id, AgentMode mode) => _update(id, (g) => g.copyWith(mode: mode.name));

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
    final gen = ++_splitGen;
    final cancel = Completer<void>();
    _splits[id] = (gen: gen, cancel: cancel);
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
            cancel: cancel.future,
          );
      if (!ref.mounted || _splits[id]?.gen != gen) return;
      switch (parsePlanSplit(reply, leads: leads, fallback: fallback, newId: planId)) {
        case SplitTasks(:final tasks):
          _update(id, (g) => g.copyWith(tasks: tasks, stage: GoalStage.ready, clearError: true));
        case SplitRefused(:final why):
          _update(id, (g) => g.copyWith(stage: GoalStage.draft, error: why));
      }
    } on Object catch (e) {
      if (!ref.mounted || _splits[id]?.gen != gen) return;
      final why = e is HarnessError ? e.message : '$e';
      _update(id, (g) => g.copyWith(stage: GoalStage.draft, error: why));
    } finally {
      if (_splits[id]?.gen == gen) _splits.remove(id);
    }
  }

  /// Ends the goal's split in flight (its planner process with it); the goal goes back to a draft.
  void stopSplit(String id) {
    if (!_endSplit(id)) return;
    if (goal(id)?.stage == GoalStage.splitting) _update(id, (g) => g.copyWith(stage: GoalStage.draft));
  }

  bool _endSplit(String id) {
    final s = _splits.remove(id);
    if (s == null) return false;
    if (!s.cancel.isCompleted) s.cancel.complete();
    return true;
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

  /// Runs a failed task again (a new session); the tasks waiting on it start once it is done.
  void retry(String goalId, String taskId) {
    final g = goal(goalId);
    final t = g?.task(taskId);
    if (g == null || t == null || g.stage == GoalStage.cancelled || t.run is! TaskFailed) return;
    _updateTask(goalId, taskId, (t) => t.copyWith(run: const TaskQueued()));
    _advance();
  }

  /// The task being started now: one at a time, so worktrees aren't made on one repository at once.
  String? _startingTask;

  /// Tasks the user cancelled with Stop while they were starting: their session is stopped once it exists.
  final _stopOnStart = <String>{};

  /// Starts the next queued task whose dependencies are done (one at a time; the next when it has started). A task
  /// in the project folder itself waits while another in-place task of that project still runs.
  void _advance() {
    if (_startingTask != null) return;
    for (final g in state) {
      for (final t in tasksToStart(g)) {
        if (!t.worktree && _inPlaceBusy(g.projectId, t.id)) continue;
        _startingTask = t.id;
        unawaited(_start(g.id, t.id));
        return;
      }
    }
  }

  bool _inPlaceBusy(String projectId, String except) => state.any(
    (g) =>
        g.projectId == projectId &&
        g.tasks.any((t) => t.id != except && !t.worktree && (t.run is TaskStarting || t.run is TaskStarted)),
  );

  Future<void> _start(String goalId, String taskId) async {
    try {
      final g = goal(goalId);
      final t = g?.task(taskId);
      final project = g == null ? null : ref.read(codeProjectsProvider).where((p) => p.id == g.projectId).firstOrNull;
      if (g == null || t == null || t.run is! TaskQueued) return;
      _updateTask(goalId, taskId, (t) => t.copyWith(run: const TaskStarting()));
      try {
        if (project == null) throw const HarnessError("The goal's project is gone.");
        final handoff = await _handoffFor(g, t);
        if (!ref.mounted) return;
        final session = await _starter.start(
          project: project,
          prompt: planTaskPrompt(g, t, handoff: handoff),
          lead: t.lead,
          worktree: t.worktree,
          mode: AgentMode.values.asNameMap()[g.mode] ?? AgentMode.autoEdit,
          fromCommit: t.worktree ? handoff.base?.commit : null,
        );
        if (!ref.mounted) return;
        // Cancelled (or its goal removed) meanwhile: the session started anyway. It is kept on the task, and stopped
        // when the user chose Stop.
        _updateTask(
          goalId,
          taskId,
          (t) => t.run is TaskCancelled
              ? t.copyWith(run: TaskCancelled(sessionId: session))
              : t.copyWith(run: TaskStarted(session)),
        );
        if (_stopOnStart.remove(taskId)) unawaited(_starter.stop(session).catchError((Object _) {}));
      } on Object catch (e) {
        if (!ref.mounted) return;
        final why = e is HarnessError ? e.message : '$e';
        _updateTask(goalId, taskId, (t) => t.run is TaskStarting ? t.copyWith(run: TaskFailed(why)) : t);
      }
    } finally {
      _stopOnStart.remove(taskId);
      if (_startingTask == taskId) _startingTask = null;
      if (ref.mounted) _advance();
    }
  }

  /// What [task] starts from: the work of the task it waits on that finished last (its worktree branches from it),
  /// the others' work to merge in first. A task in the project folder merges them all.
  Future<TaskHandoff> _handoffFor(PlanGoal goal, GoalTask task) async {
    if (task.after.isEmpty) return noHandoff;
    ({String title, String commit})? base;
    final merges = <({String title, String commit})>[];
    final inPlace = <String>[];
    for (final dep in depsByFinish(goal, task)) {
      final session = sessionOfRun(dep.run);
      final commit = session == null ? null : await _starter.handoff(session);
      if (commit == null) {
        inPlace.add(dep.title);
      } else if (base == null && task.worktree) {
        base = (title: dep.title, commit: commit);
      } else {
        merges.add((title: dep.title, commit: commit));
      }
    }
    return (base: base, merges: merges, inPlace: inPlace);
  }

  /// What the started tasks' sessions are doing ([outcomes] by session id; a session missing from it is left alone):
  /// finished ones mark their task done or failed, which may start the tasks waiting on them.
  void observe(Map<String, SessionOutcome> outcomes, {DateTime? now}) {
    var changed = false;
    final at = now ?? DateTime.now();
    final next = [
      for (final g in state)
        g.copyWith(
          tasks: [
            for (final t in g.tasks)
              switch ((t.run, outcomes[sessionOfRun(t.run)])) {
                (TaskStarted(:final sessionId), SessionOutcome.done) => () {
                  changed = true;
                  return t.copyWith(run: TaskDone(sessionId, at: at));
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

  /// Stops the goal: drafts and queued tasks are cancelled. Started ones (and ones starting now) keep running unless
  /// [started] is [StartedChoice.stop]; then their sessions are stopped. The goal is cancelled.
  void cancel(String goalId, {StartedChoice started = StartedChoice.keepRunning}) {
    final g = goal(goalId);
    if (g == null) return;
    _endSplit(goalId);
    final stop = started == StartedChoice.stop;
    final sessions = <String>[];
    _update(
      goalId,
      (g) => g.copyWith(
        stage: GoalStage.cancelled,
        tasks: [
          for (final t in g.tasks)
            switch (t.run) {
              TaskDraft() || TaskQueued() => t.copyWith(run: const TaskCancelled()),
              TaskStarting() => () {
                if (stop) _stopOnStart.add(t.id);
                return t.copyWith(run: const TaskCancelled());
              }(),
              TaskStarted(:final sessionId) when stop => () {
                sessions.add(sessionId);
                return t.copyWith(run: TaskCancelled(sessionId: sessionId));
              }(),
              _ => t,
            },
        ],
      ),
    );
    for (final s in sessions) {
      unawaited(_starter.stop(s).catchError((Object _) {}));
    }
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
      // Settled on load: runners that were starting came back failed, which may make the race ready to compare.
      return [
        for (final r in jsonDecode(raw) as List<Object?>)
          if (BoardRace.fromJson(r) case final r?) r.copyWith(stage: settleRace(r)),
      ];
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

  BoardStarter get _starter => ref.read(boardStarterProvider);

  /// Starts a race of [prompt] in [project] on each of [leads] (2–4), each in its own worktree, one after another (so
  /// worktrees aren't made on one repository at once); its id.
  String start({
    required CodeProject project,
    required String prompt,
    required List<LeadPick> leads,
    String? goalId,
    AgentMode mode = AgentMode.autoEdit,
  }) {
    final id = planId();
    final now = DateTime.now();
    final picked = leads.take(4).toList();
    _set([
      BoardRace(
        id: id,
        projectId: project.id,
        prompt: prompt,
        runners: [for (final l in picked) RaceRunner(lead: l, startedAt: now)],
        createdAt: now,
        goalId: goalId,
      ),
      ...state,
    ]);
    unawaited(() async {
      for (final (i, l) in picked.indexed) {
        if (!ref.mounted) return;
        await _startRunner(id, i, project, prompt, l, mode);
      }
    }());
    return id;
  }

  Future<void> _startRunner(
    String raceId,
    int index,
    CodeProject project,
    String prompt,
    LeadPick lead,
    AgentMode mode,
  ) async {
    // Cancelled before its turn came: it never starts.
    final before = race(raceId);
    if (before == null || before.stage == RaceStage.cancelled || before.runners[index].run is! RunnerStarting) {
      if (before != null && before.runners[index].run is RunnerStarting) {
        _setRunner(raceId, index, const RunnerDiscarded());
      }
      return;
    }
    RunnerRun run;
    try {
      final session = await _starter.start(project: project, prompt: prompt, lead: lead, worktree: true, mode: mode);
      run = RunnerRunning(session);
    } on Object catch (e) {
      run = RunnerFailed(e is HarnessError ? e.message : '$e');
    }
    if (!ref.mounted) return;
    final r = race(raceId);
    final session = sessionOfRunner(run);
    // The race was cancelled with Stop, or removed, while this runner started: its session goes too.
    if (session != null && (r == null || r.stage == RaceStage.cancelled && _stopRaces.contains(raceId))) {
      unawaited(_stopAndDiscard(session));
      if (r != null) _setRunner(raceId, index, const RunnerDiscarded());
      return;
    }
    _setRunner(raceId, index, run, onlyFromStarting: true);
  }

  void _setRunner(String raceId, int index, RunnerRun run, {bool onlyFromStarting = false}) => _update(raceId, (r) {
    final runners = [...r.runners];
    if (index < runners.length && (!onlyFromStarting || runners[index].run is RunnerStarting)) {
      runners[index] = runners[index].copyWith(run: run, startedAt: DateTime.now());
    }
    return r.copyWith(runners: runners);
  });

  Future<void> _stopAndDiscard(String session) async {
    try {
      await _starter.stop(session);
      await _starter.discard(session);
    } on Object {
      // Already gone.
    }
  }

  /// Races cancelled with Stop: runners still starting are stopped and removed once they exist.
  final _stopRaces = <String>{};

  /// What the runners' sessions are doing; finished runners record when.
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

  /// Why Keep can't run on [id] now, or null: a runner is still starting (its session and worktree would be lost
  /// track of).
  String? keepBlocked(String id) {
    final r = race(id);
    if (r == null) return 'The race is gone.';
    if (r.runners.any((x) => x.run is RunnerStarting)) return 'A runner is still starting. Keep once it has started.';
    return null;
  }

  /// Records the user's pick after the winner merged: [session]'s runner is kept, every other runner discarded.
  /// Their worktrees are the caller's to remove.
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

  /// Cancels the race. With [StartedChoice.stop] its runners are stopped and removed with their worktrees (now, or
  /// once a starting one exists); else they keep running as ordinary sessions.
  void cancel(String id, {StartedChoice started = StartedChoice.keepRunning}) {
    final r = race(id);
    if (r == null) return;
    final stop = started == StartedChoice.stop;
    if (stop) _stopRaces.add(id);
    final sessions = [
      for (final x in r.runners)
        if (x.run is RunnerRunning || x.run is RunnerDone) ?sessionOfRunner(x.run),
    ];
    _update(
      id,
      (r) => r.copyWith(
        stage: RaceStage.cancelled,
        runners: [
          for (final x in r.runners)
            stop && (x.run is RunnerRunning || x.run is RunnerDone) ? x.copyWith(run: const RunnerDiscarded()) : x,
        ],
      ),
    );
    if (stop) {
      for (final s in sessions) {
        unawaited(_stopAndDiscard(s));
      }
    }
  }

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

/// What a tracked session is doing, from its own status ([own]: the live one when its view is open, else the polled
/// one) and whether forks or subagents under it still work: done only when it is done (not merely idle, which a
/// session reads before its first turn) and nothing under it runs.
SessionOutcome sessionOutcome({
  required CodeSessionInfo? info,
  required SessionStatus? own,
  required bool childrenWorking,
}) {
  if (info == null) return SessionOutcome.gone;
  if (info.removedHarness || own == SessionStatus.failed) return SessionOutcome.failed;
  if (own == SessionStatus.done && !childrenWorking) return SessionOutcome.done;
  return SessionOutcome.running;
}

/// Follows the sessions the plans and races started, app-wide (the shell keeps it on desktop): a finished one moves
/// its task or runner on, which may start the tasks waiting on it, wherever the user is. Watches nothing while no
/// task or runner runs.
final boardPlanWatchProvider = Provider<void>((ref) {
  final goals = ref.watch(boardPlansProvider);
  final races = ref.watch(boardRacesProvider);
  final tracked = {
    for (final g in goals)
      for (final t in g.tasks)
        if (t.run case TaskStarted(:final sessionId)) sessionId,
    for (final r in races)
      for (final x in r.runners)
        if (x.run case RunnerRunning(:final sessionId)) sessionId,
  };
  if (tracked.isEmpty) return;
  final sessions = ref.watch(codeSessionsProvider);
  final polled = ref.watch(codeStatusesProvider);
  // Re-read when a session's view opens or closes (its live status then counts).
  ref.watch(openCodeSessionsProvider);
  final byId = {for (final s in sessions) s.id: s};
  SessionStatus? ownOf(String id) {
    final live = ref.exists(codeSessionProvider(id))
        ? ref.watch(codeSessionProvider(id).select((st) => st.connected || st.failure != null ? st.status : null))
        : null;
    return live ?? polled[id];
  }

  final children = childrenByParent(sessions);
  final outcomes = <String, SessionOutcome>{
    for (final id in tracked)
      id: sessionOutcome(
        info: byId[id],
        own: ownOf(id),
        childrenWorking: runningDescendants(id, children, (c) => ownOf(c.id) ?? SessionStatus.idle) > 0,
      ),
  };
  if (outcomes.values.every((o) => o == SessionOutcome.running)) return;
  // Not while this provider builds: the notifiers it watches change.
  Future.microtask(() {
    if (!ref.mounted) return;
    ref.read(boardPlansProvider.notifier).observe(outcomes);
    ref.read(boardRacesProvider.notifier).observe(outcomes);
  });
});

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
