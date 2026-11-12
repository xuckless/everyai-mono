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
import '../ui/skip_permissions_consent.dart' show SkipPermissionsConsent, skipPermissionsProvider, skipsPermissions;
import 'board_plan.dart';
import 'board_planner.dart';
import 'board_providers.dart' show childrenByParent;
import 'board_race.dart';
import 'board_state.dart' show runningDescendants;

/// What a task's or runner's session is doing, as the plans see it ([boardPlanWatchProvider]): [working] when it (or
/// something under it) is at work, [running] when it is neither at work nor finished (idle, not opened yet).
enum SessionOutcome { working, running, done, failed, gone }

/// The mode Board work on [harness] starts in, from the goal's or race's pick ([picked]: an AgentMode name or
/// [autonomousMode]). Owner: as autonomous as possible. [autonomousMode] is Full auto on the EveryAI lead; an outside
/// lead gets its own skip-permissions mode (Full auto) only when the user already agreed to it for that harness
/// ([skipAllowed]; nothing asks from the Board), else Auto-edit. A picked skip-permissions mode follows the same rule.
AgentMode boardStartMode(String picked, String harness, {required bool Function(String harness) skipAllowed}) {
  final outside = harness != everyaiHarnessName;
  final mode = picked == autonomousMode
      ? AgentMode.fullAuto
      : AgentMode.values.asNameMap()[picked] ?? AgentMode.fullAuto;
  if (outside && skipsPermissions(mode) && !skipAllowed(harness)) return AgentMode.autoEdit;
  return mode;
}

/// What happens to the sessions a goal or race already started when the user cancels or removes it.
enum StartedChoice { keepRunning, stop }

/// The Board's goals (Preferences `code.board.plans`; no cap on goals or tasks). Moves goals and tasks along their
/// diagrams in board_plan.dart. Tasks start in the background wherever the user is ([boardPlanWatchProvider] reports
/// their sessions, app-wide).
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
      final starter = ref.read(boardStarterProvider);
      final stops = <String>[];
      // Recovered on load: a task the app quit while starting is started when its session was saved (found by the
      // id picked before the start), else failed; one the user had stopped is cancelled (its session stopped). Then
      // settled, which may finish its goal; removed goals waiting on such a start go.
      final goals = [
        for (final g in jsonDecode(raw) as List<Object?>)
          if (PlanGoal.fromJson(g) case final g?)
            () {
              final cancelled = g.stage == GoalStage.cancelled || g.stage == GoalStage.removing;
              final tasks = [
                for (final t in g.tasks)
                  () {
                    if (t.run case TaskStopping(:final sessionId) when starter.exists(sessionId)) stops.add(sessionId);
                    return t.copyWith(
                      run: recoverTask(t.run, exists: starter.exists, cancelled: cancelled),
                    );
                  }(),
              ];
              final next = g.copyWith(tasks: tasks);
              return next.copyWith(stage: settleGoal(next));
            }(),
      ].where((g) => g.stage != GoalStage.removing).toList();
      // Queued tasks whose dependencies finished while the app was closed start now.
      Future.microtask(() {
        if (!ref.mounted) return;
        for (final s in stops) {
          unawaited(_starter.stop(s).catchError((Object _) {}));
        }
        _advance();
      });
      return goals;
    } on Object {
      return const [];
    }
  }

  /// Saves [goals] settled; a removed goal goes once none of its tasks' sessions is still being made.
  void _set(List<PlanGoal> goals) {
    final settled = [
      for (final g in goals)
        if (g.stage != GoalStage.removing || g.tasks.any((t) => taskPending(t.run))) g.copyWith(stage: settleGoal(g)),
    ];
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
        g.tasks.any((t) => t.run is TaskQueued || taskPending(t.run) || t.run is TaskStarted);
  }

  /// Removes the goal: a split in flight ends, queued tasks never start, and started sessions are stopped with
  /// [started] = [StartedChoice.stop] (else left running, without the goal). A task whose session is still being made
  /// keeps the goal (hidden, [GoalStage.removing]) until that session exists and the choice is applied to it.
  void remove(String id, {StartedChoice started = StartedChoice.keepRunning}) {
    _endSplit(id);
    if (busy(id)) cancel(id, started: started);
    _update(id, (g) => g.copyWith(stage: GoalStage.removing));
  }

  void setText(String id, String text) => _update(id, (g) => g.copyWith(text: text));
  void setProject(String id, String projectId) => _update(id, (g) => g.copyWith(projectId: projectId));
  void setPlanner(String id, LeadPick planner) => _update(id, (g) => g.copyWith(planner: planner));

  /// The mode the goal's tasks start in: an AgentMode name or [autonomousMode] (tasks already started keep theirs).
  void setMode(String id, String mode) => _update(id, (g) => g.copyWith(mode: mode));

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

  /// Starts the next queued task whose dependencies are done, one at a time (none while a task's session is still
  /// being made, so worktrees aren't made on one repository at once). A task in the project folder itself waits while
  /// another in-place task of that project still runs (they would edit the same checkout).
  void _advance() {
    if (state.any((g) => g.tasks.any((t) => taskPending(t.run)))) return;
    for (final g in state) {
      for (final t in tasksToStart(g)) {
        if (!t.worktree && _inPlaceBusy(g.projectId, t.id)) continue;
        // The session id is picked and saved before anything starts, so a quit mid-start is found again.
        final session = _starter.newSessionId();
        _updateTask(g.id, t.id, (t) => t.copyWith(run: TaskStarting(session)));
        unawaited(_start(g.id, t.id, session));
        return;
      }
    }
  }

  bool _inPlaceBusy(String projectId, String except) => state.any(
    (g) =>
        g.projectId == projectId &&
        g.tasks.any((t) => t.id != except && !t.worktree && (taskPending(t.run) || t.run is TaskStarted)),
  );

  Future<void> _start(String goalId, String taskId, String session) async {
    String? why;
    try {
      final g = goal(goalId);
      final t = g?.task(taskId);
      final project = g == null ? null : ref.read(codeProjectsProvider).where((p) => p.id == g.projectId).firstOrNull;
      if (g == null || t == null) throw const HarnessError('The task is gone.');
      if (project == null) throw const HarnessError("The goal's project is gone.");
      final handoff = await _handoffFor(g, t);
      if (!ref.mounted) return;
      await _starter.start(
        sessionId: session,
        project: project,
        prompt: planTaskPrompt(g, t, handoff: handoff),
        lead: t.lead,
        worktree: t.worktree,
        mode: boardStartMode(g.mode, t.lead.harness, skipAllowed: _skipAllowed),
        fromCommit: t.worktree ? handoff.base?.commit : null,
      );
    } on Object catch (e) {
      why = e is HarnessError ? e.message : '$e';
    }
    if (!ref.mounted) return;
    _landed(goalId, taskId, session, why);
    _advance();
  }

  bool _skipAllowed(String harness) =>
      ref.read(skipPermissionsProvider.notifier).of(harness) == SkipPermissionsConsent.allowed;

  /// A start landed ([why]: it failed): starting → started (or cancelled, keeping its session, when the goal was
  /// cancelled or removed meanwhile with Keep them running); stopping → its session stopped, cancelled.
  void _landed(String goalId, String taskId, String session, String? why) {
    final g = goal(goalId);
    final t = g?.task(taskId);
    if (g == null || t == null) return;
    final cancelled = g.stage == GoalStage.cancelled || g.stage == GoalStage.removing;
    final TaskRun next;
    switch (t.run) {
      case TaskStarting(:final sessionId) when sessionId == session:
        next = why != null
            ? (cancelled ? const TaskCancelled() : TaskFailed(why))
            : (cancelled ? TaskCancelled(sessionId: session) : TaskStarted(session));
      case TaskStopping(:final sessionId) when sessionId == session:
        if (why == null) unawaited(_starter.stop(session).catchError((Object _) {}));
        next = TaskCancelled(sessionId: why == null ? session : null);
      case _:
        return;
    }
    _updateTask(goalId, taskId, (t) => t.copyWith(run: next));
  }

  /// What [task] starts from: the work of the task it waits on that finished last (its worktree branches from it),
  /// the others' work to merge in first. A task in the project folder merges them all.
  Future<TaskHandoff> _handoffFor(PlanGoal goal, GoalTask task) async {
    if (task.after.isEmpty) return noHandoff;
    ({String title, String commit})? base;
    final merges = <({String title, String commit})>[];
    final inPlace = <String>[];
    final missing = <String>[];
    for (final dep in depsByFinish(goal, task)) {
      final session = sessionOfRun(dep.run);
      final commit = session == null || !dep.worktree ? null : await _starter.handoff(session);
      if (!dep.worktree) {
        inPlace.add(dep.title);
      } else if (commit == null) {
        // On its own branch, but its session or worktree is gone: not "ran in the project folder".
        missing.add(dep.title);
      } else if (base == null && task.worktree) {
        base = (title: dep.title, commit: commit);
      } else {
        merges.add((title: dep.title, commit: commit));
      }
    }
    return (base: base, merges: merges, inPlace: inPlace, missing: missing);
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
              // Its session is being made: with Stop it is stopped once it exists; else it lands as a cancelled task
              // whose session keeps running.
              TaskStarting(:final sessionId) when stop => t.copyWith(run: TaskStopping(sessionId)),
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
    for (final g in shownGoals(state))
      for (final t in g.tasks) ?sessionOfRun(t.run): g,
  };
}

/// The Board's races (Preferences `code.board.races`). Moves races and runners along their diagrams in
/// board_race.dart. No cap on races or runners.
final boardRacesProvider = NotifierProvider<BoardRaces, List<BoardRace>>(BoardRaces.new);

final class BoardRaces extends Notifier<List<BoardRace>> {
  static const key = 'code.board.races';

  @override
  List<BoardRace> build() {
    final raw = ref.read(preferencesProvider)[key];
    if (raw == null) return const [];
    try {
      final starter = ref.read(boardStarterProvider);
      final removals = <String>[];
      // Recovered on load: a runner the app quit while starting is running when its session was saved (found by the
      // id picked before the start), else failed; one the user had stopped is removed with its session. Removed
      // races waiting on such a start go. Then settled (a race whose runners all finished is ready to compare).
      final races = [
        for (final r in jsonDecode(raw) as List<Object?>)
          if (BoardRace.fromJson(r) case final r?)
            () {
              final runners = [
                for (final x in r.runners)
                  () {
                    if (x.run case RunnerStopping(:final sessionId) when starter.exists(sessionId)) {
                      removals.add(sessionId);
                    }
                    return x.copyWith(run: recoverRunner(x.run, exists: starter.exists));
                  }(),
              ];
              final next = r.copyWith(runners: runners);
              return next.copyWith(stage: settleRace(next));
            }(),
      ].where((r) => r.stage is! RaceRemoving).toList();
      Future.microtask(() async {
        if (!ref.mounted) return;
        for (final s in removals) {
          unawaited(_stopAndDiscard(s));
        }
        // Queued runners start; a Keep the app quit during goes on where it was.
        _advance();
        for (final r in races) {
          if (r.stage case RaceKeeping(:final step)) {
            await (step == KeepStep.merging ? settleKeep(r.id, merged: false) : _removeLosers(r.id));
          }
        }
      });
      return races;
    } on Object {
      return const [];
    }
  }

  /// Saves [races] settled; a removed race goes once none of its runners' sessions is still being made.
  void _set(List<BoardRace> races) {
    final settled = [
      for (final r in races)
        if (r.stage is! RaceRemoving || r.runners.any((x) => runnerPending(x.run))) r.copyWith(stage: settleRace(r)),
    ];
    state = settled;
    ref.read(preferencesProvider)[key] = jsonEncode([for (final r in settled) r.toJson()]);
  }

  BoardRace? race(String id) => state.where((r) => r.id == id).firstOrNull;

  void _update(String id, BoardRace Function(BoardRace r) change) =>
      _set([for (final r in state) r.id == id ? change(r) : r]);

  void _updateRunner(String raceId, int index, RunnerRun Function(RaceRunner x) change, {DateTime? startedAt}) =>
      _update(raceId, (r) {
        if (index >= r.runners.length) return r;
        final runners = [...r.runners];
        runners[index] = runners[index].copyWith(run: change(runners[index]), startedAt: startedAt);
        return r.copyWith(runners: runners);
      });

  BoardStarter get _starter => ref.read(boardStarterProvider);

  /// Starts a race of [prompt] in [project] on each of [leads] (as many as the user picked), each in its own
  /// worktree, one after another (so worktrees aren't made on one repository at once); its id. [mode] is the pick
  /// the runners start in ([boardStartMode]).
  String start({
    required CodeProject project,
    required String prompt,
    required List<LeadPick> leads,
    String? goalId,
    String mode = autonomousMode,
  }) {
    final id = planId();
    final now = DateTime.now();
    _set([
      BoardRace(
        id: id,
        projectId: project.id,
        prompt: prompt,
        runners: [
          for (final l in leads) RaceRunner(lead: l, run: RunnerQueued(_starter.newSessionId()), startedAt: now),
        ],
        createdAt: now,
        goalId: goalId,
        mode: mode,
      ),
      ...state,
    ]);
    _advance();
    return id;
  }

  /// Starts the next queued runner (the oldest race first), one at a time: none while a runner's session is still
  /// being made.
  void _advance() {
    if (state.any((r) => r.runners.any((x) => runnerPending(x.run)))) return;
    for (final r in state.reversed) {
      for (final (i, x) in r.runners.indexed) {
        if (x.run case RunnerQueued(:final sessionId)) {
          _updateRunner(r.id, i, (_) => RunnerStarting(sessionId), startedAt: DateTime.now());
          unawaited(_startRunner(r.id, i, sessionId));
          return;
        }
      }
    }
  }

  Future<void> _startRunner(String raceId, int index, String session) async {
    String? why;
    try {
      final r = race(raceId);
      final project = r == null ? null : ref.read(codeProjectsProvider).where((p) => p.id == r.projectId).firstOrNull;
      if (r == null) throw const HarnessError('The race is gone.');
      if (project == null) throw const HarnessError("The race's project is gone.");
      final lead = r.runners[index].lead;
      await _starter.start(
        sessionId: session,
        project: project,
        prompt: r.prompt,
        lead: lead,
        worktree: true,
        mode: boardStartMode(r.mode, lead.harness, skipAllowed: _skipAllowed),
      );
    } on Object catch (e) {
      why = e is HarnessError ? e.message : '$e';
    }
    if (!ref.mounted) return;
    // starting → running (also when the race was cancelled or removed with Keep them running: it runs on as an
    // ordinary session) or failed; stopping → its session stopped and removed.
    _updateRunner(raceId, index, (x) {
      switch (x.run) {
        case RunnerStarting(:final sessionId) when sessionId == session:
          return why == null ? RunnerRunning(session) : RunnerFailed(why);
        case RunnerStopping(:final sessionId) when sessionId == session:
          if (why == null) unawaited(_stopAndDiscard(session));
          return const RunnerDiscarded();
        case final other:
          return other;
      }
    });
    _advance();
  }

  bool _skipAllowed(String harness) =>
      ref.read(skipPermissionsProvider.notifier).of(harness) == SkipPermissionsConsent.allowed;

  Future<void> _stopAndDiscard(String session) async {
    try {
      await _starter.stop(session);
      await _starter.discard(session);
    } on Object {
      // Already gone.
    }
  }

  /// Whether the runners of a race in [stage] are followed (a kept, cancelled or removed race lets them go).
  static bool follows(RaceStage stage) => stage is! RaceKept && stage is! RaceCancelled && stage is! RaceRemoving;

  /// What the runners' sessions are doing, followed live: finished runners record when; a done or failed runner
  /// whose session works again is running again (Keep waits for it); a deleted session is gone.
  void observe(Map<String, SessionOutcome> outcomes, {DateTime? now}) {
    var changed = false;
    final at = now ?? DateTime.now();
    RaceRunner move(RaceRunner x, RunnerRun run) {
      changed = true;
      return x.copyWith(run: run);
    }

    final next = [
      for (final r in state)
        if (!follows(r.stage))
          r
        else
          r.copyWith(
            runners: [
              for (final x in r.runners)
                switch ((x.run, outcomes[sessionOfRunner(x.run)])) {
                  (RunnerRunning(:final sessionId), SessionOutcome.done) => move(x, RunnerDone(sessionId, at)),
                  (RunnerRunning(:final sessionId) || RunnerDone(:final sessionId), SessionOutcome.failed) => move(
                    x,
                    RunnerFailed('Its session failed.', sessionId: sessionId),
                  ),
                  (RunnerDone(:final sessionId), SessionOutcome.working) => move(x, RunnerRunning(sessionId)),
                  (RunnerFailed(sessionId: final sessionId?), SessionOutcome.working) => move(
                    x,
                    RunnerRunning(sessionId),
                  ),
                  (RunnerRunning(:final sessionId) || RunnerDone(:final sessionId), SessionOutcome.gone) => move(
                    x,
                    RunnerGone(sessionId),
                  ),
                  (RunnerFailed(sessionId: final sessionId?), SessionOutcome.gone) => move(x, RunnerGone(sessionId)),
                  _ => x,
                },
            ],
          ),
    ];
    if (changed) _set(next);
  }

  /// Compare now: the race shows its Compare view even while runners still work.
  void compare(String id) => _update(id, (r) => r.stage is RaceRunning ? r.copyWith(stage: const RaceComparing()) : r);

  /// Whether some runner of [id] still works or waits to start (the card offers Stop for them).
  bool working(String id) =>
      race(id)?.runners.any((x) => x.run is RunnerRunning || x.run is RunnerQueued || x.run is RunnerStarting) ?? false;

  /// Stops the runners still at work, keeping the race and the finished ones to compare: running ones are stopped
  /// (shown "Stopped by you"; one that works again is followed again), queued ones never start, ones being made are
  /// stopped and removed once they exist.
  void stopWorking(String id) {
    final sessions = <String>[];
    _update(
      id,
      (r) => r.copyWith(
        runners: [
          for (final x in r.runners)
            switch (x.run) {
              RunnerRunning(:final sessionId) => () {
                sessions.add(sessionId);
                return x.copyWith(run: RunnerFailed('Stopped by you.', sessionId: sessionId));
              }(),
              RunnerQueued() => x.copyWith(run: const RunnerDiscarded()),
              RunnerStarting(:final sessionId) => x.copyWith(run: RunnerStopping(sessionId)),
              _ => x,
            },
        ],
      ),
    );
    for (final s in sessions) {
      unawaited(_starter.stop(s).catchError((Object _) {}));
    }
  }

  /// Why Keep can't run on [winner] of [id] now, or null: a runner is still starting (its session and worktree would
  /// be lost track of), a Keep already runs, or the winner isn't finished (it works again, failed or is gone).
  String? keepBlocked(String id, {String? winner}) {
    final r = race(id);
    if (r == null) return 'The race is gone.';
    if (r.stage is RaceKeeping) return 'A Keep is already running.';
    if (r.stage is RaceKept || r.stage is RaceCancelled) return 'This race is over.';
    if (r.runners.any((x) => x.run is RunnerQueued || runnerPending(x.run))) {
      return 'A runner is still starting. Keep once it has started.';
    }
    if (winner != null && !r.runners.any((x) => x.run is RunnerDone && sessionOfRunner(x.run) == winner)) {
      return 'That runner isn\'t finished. Keep it once it is done.';
    }
    return null;
  }

  /// Keep, step one: [winner] (a finished runner) is being merged by the caller (the session's own merge, with its
  /// confirms). Null when it began, else why not. Report the merge with [settleKeep].
  String? beginKeep(String id, String winner) {
    if (keepBlocked(id, winner: winner) case final why?) return why;
    _update(id, (r) => r.copyWith(stage: RaceKeeping(winner, KeepStep.merging)));
    return null;
  }

  /// Keep, step two: whether the winner's work landed ([merged], or found on its base branch when the caller couldn't
  /// say, as after a quit). Landed: the other runners are stopped and their worktrees removed (branches kept), then
  /// the race is kept. Not landed: back to comparing, nothing lost.
  Future<void> settleKeep(String id, {required bool merged}) async {
    final r = race(id);
    if (r == null) return;
    if (r.stage case RaceKeeping(:final winner, step: KeepStep.merging)) {
      final landed = merged || await _starter.landed(winner);
      if (!ref.mounted) return;
      if (!landed) {
        _update(id, (r) => r.stage is RaceKeeping ? r.copyWith(stage: const RaceComparing()) : r);
        return;
      }
      _update(id, (r) => r.copyWith(stage: RaceKeeping(winner, KeepStep.removingLosers)));
      await _removeLosers(id);
    }
  }

  /// Every runner but the winner: stopped when at work, its worktree removed with its session (its branch is kept).
  /// One that can't be removed says why on its tile. Then the race is kept.
  Future<void> _removeLosers(String id) async {
    final r = race(id);
    if (r == null) return;
    final winner = winnerOf(r.stage);
    if (winner == null) return;
    for (final (i, x) in r.runners.indexed) {
      final session = sessionOfRunner(x.run);
      if (session == winner) continue;
      if (session == null) {
        if (x.run is! RunnerDiscarded) _updateRunner(id, i, (_) => const RunnerDiscarded());
        continue;
      }
      RunnerRun next;
      try {
        if (x.run is RunnerRunning) await _starter.stop(session);
        await _starter.discard(session);
        next = const RunnerDiscarded();
      } on Object catch (e) {
        next = RunnerFailed("Couldn't remove its worktree: $e", sessionId: session);
      }
      if (!ref.mounted) return;
      _updateRunner(id, i, (_) => next);
    }
    _update(id, (r) => r.copyWith(stage: RaceKept(winner)));
  }

  /// Cancels the race. Runners waiting for their turn never start. With [StartedChoice.stop] the others are stopped
  /// and removed with their worktrees (branches kept): now, or once a starting one's session exists. Else they keep
  /// running as ordinary sessions. The choice is kept on each runner ([RunnerStopping]), so removing the race later,
  /// or a quit, doesn't change it.
  void cancel(String id, {StartedChoice started = StartedChoice.keepRunning}) {
    final r = race(id);
    if (r == null) return;
    final stop = started == StartedChoice.stop;
    final sessions = <String>[];
    _update(
      id,
      (r) => r.copyWith(
        stage: const RaceCancelled(),
        runners: [
          for (final x in r.runners)
            switch (x.run) {
              RunnerQueued() => x.copyWith(run: const RunnerDiscarded()),
              RunnerStarting(:final sessionId) when stop => x.copyWith(run: RunnerStopping(sessionId)),
              RunnerRunning(:final sessionId) ||
              RunnerDone(:final sessionId) ||
              RunnerFailed(sessionId: final sessionId?) when stop => () {
                sessions.add(sessionId);
                return x.copyWith(run: const RunnerDiscarded());
              }(),
              _ => x,
            },
        ],
      ),
    );
    for (final s in sessions) {
      unawaited(_stopAndDiscard(s));
    }
  }

  /// Takes the race off the lane. Its runners are left as they are (the choice made at Cancel stands); one whose
  /// session is still being made keeps the race, hidden, until it exists.
  void remove(String id) => _update(
    id,
    (r) => r.copyWith(
      stage: const RaceRemoving(),
      runners: [for (final x in r.runners) x.run is RunnerQueued ? x.copyWith(run: const RunnerDiscarded()) : x],
    ),
  );

  /// The race each runner's session belongs to.
  Map<String, BoardRace> get bySession => {
    for (final r in shownRaces(state))
      for (final x in r.runners) ?sessionOfRunner(x.run): r,
  };
}

/// What a tracked session is doing, from its own status ([own]: the live one when its view is open, else the polled
/// one) and whether forks or subagents under it still work: done only when it is done (not merely idle, which a
/// session reads before its first turn) and nothing under it runs; working when it or something under it is at work.
SessionOutcome sessionOutcome({
  required CodeSessionInfo? info,
  required SessionStatus? own,
  required bool childrenWorking,
}) {
  if (info == null) return SessionOutcome.gone;
  if (info.removedHarness || own == SessionStatus.failed) return SessionOutcome.failed;
  if (own == SessionStatus.done && !childrenWorking) return SessionOutcome.done;
  if (childrenWorking ||
      own == SessionStatus.starting ||
      own == SessionStatus.running ||
      own == SessionStatus.needsInput ||
      own == SessionStatus.paused) {
    return SessionOutcome.working;
  }
  return SessionOutcome.running;
}

/// Follows the sessions the plans and races started, app-wide (the shell keeps it on desktop): a finished one moves
/// its task or runner on, which may start the tasks waiting on it, wherever the user is. A race's finished runners
/// are followed too (one that works again is running again; a deleted one is gone). Watches nothing while there is
/// nothing to follow.
final boardPlanWatchProvider = Provider<void>((ref) {
  final goals = ref.watch(boardPlansProvider);
  final races = ref.watch(boardRacesProvider);
  final tracked = {
    for (final g in goals)
      for (final t in g.tasks)
        if (t.run case TaskStarted(:final sessionId)) sessionId,
    for (final r in races)
      if (BoardRaces.follows(r.stage))
        for (final x in r.runners)
          if (x.run
              case RunnerRunning(:final sessionId) ||
                  RunnerDone(:final sessionId) ||
                  RunnerFailed(sessionId: final sessionId?))
            sessionId,
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
  // Otherwise the notifiers decide whether anything moved (a done runner still done changes nothing).
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
