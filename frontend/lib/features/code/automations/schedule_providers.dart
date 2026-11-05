import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/preferences.dart';
import '../agent_models.dart' show codeAgentProvider;
import '../code_providers.dart';
import '../domain/agent_mode.dart';
import '../domain/code_session.dart';
import '../harness/harness.dart' show HarnessError;
import '../session_notifications.dart' show systemNotifierProvider;
import 'schedule.dart';

/// The current time; tests replace it.
final scheduleClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// How often the runner looks for due tasks; null (tests) starts no timer.
final scheduleTickProvider = Provider<Duration?>((ref) => const Duration(seconds: 30));

/// Starts the session for a task: the same path as the new-session sheet. Tests replace it.
final scheduleStarterProvider = Provider<Future<CodeSessionInfo> Function(ScheduledTask)>(
  (ref) =>
      (task) => startTaskSession(ref, task),
);

/// Whether the session [id] (started by a task in this run of the app) is still working.
final scheduleSessionActiveProvider = Provider<bool Function(String)>(
  (ref) =>
      // A session nobody has open has no controller, and reading one here would build it just to ask.
      (id) =>
          ref.exists(codeSessionProvider(id)) &&
          switch (ref.read(codeSessionProvider(id)).status) {
            SessionStatus.starting || SessionStatus.running || SessionStatus.needsInput => true,
            _ => false,
          },
);

/// Starts a normal Code session for [task], so the consent, permission and floor checks of every session apply.
/// An empty model or effort means what is picked for that lead now. Also the entry point other triggers can use.
Future<CodeSessionInfo> startTaskSession(Ref ref, ScheduledTask task) async {
  final project = ref.read(codeProjectsProvider).where((p) => p.id == task.projectId).firstOrNull;
  if (project == null) throw StateError('The project is gone. Pick another one for this task.');
  if (noLocalFolder(project.path)) throw StateError('Scheduled tasks run on this computer only.');
  final picked = task.harness == everyaiHarnessName
      ? (model: ref.read(codeAgentProvider).model, effort: ref.read(codeAgentProvider).effort)
      : ref.read(codeLeadProvider).of(task.harness);
  final sessions = ref.read(codeSessionsProvider.notifier);
  final info = await sessions.start(
    project: project,
    prompt: task.prompt,
    model: task.model.isEmpty ? picked.model : task.model,
    effort: task.effort.isEmpty ? picked.effort : task.effort,
    mode: task.mode,
    harness: task.harness,
  );
  final titled = info.copyWith(title: task.name);
  sessions.update(titled);
  // The controller answers the harness's approvals for the mode, notifies and enforces the budget; the session
  // view builds it for a session started by hand, and nobody opens this one. The provider keeps it alive.
  ref.read(codeSessionProvider(info.id));
  return titled;
}

/// The scheduled tasks (Preferences `code.schedules`).
final scheduledTasksProvider = NotifierProvider<ScheduledTasks, List<ScheduledTask>>(ScheduledTasks.new);

final class ScheduledTasks extends Notifier<List<ScheduledTask>> {
  static const _key = 'code.schedules';

  /// Tasks whose planned start passed while the app was closed or asleep, by the time they were due. They do not
  /// run by themselves: the list offers Run now.
  Map<String, DateTime> missed = const {};

  @override
  List<ScheduledTask> build() {
    final raw = ref.read(preferencesProvider)[_key];
    if (raw == null) return const [];
    final now = ref.read(scheduleClockProvider)();
    final missed = <String, DateTime>{};
    final tasks = <ScheduledTask>[];
    var unreadable = false;
    try {
      for (final j in jsonDecode(raw) as List<Object?>) {
        try {
          var t = ScheduledTask.fromJson(j! as Map<String, Object?>);
          if (t.enabled && (t.nextRun == null || !t.nextRun!.isAfter(now))) {
            if (t.nextRun != null) missed[t.id] = t.nextRun!;
            t = t.copyWith(nextRun: t.schedule.next(now));
          }
          tasks.add(t);
        } on Object {
          // One entry this build can't read (maybe from a newer one): skip it.
          unreadable = true;
        }
      }
    } on Object {
      unreadable = true;
    }
    this.missed = missed;
    // Stored entries that couldn't be read stay as they are until the user changes the list.
    if (!unreadable) _save(tasks);
    return tasks;
  }

  void _save([List<ScheduledTask>? tasks]) =>
      ref.read(preferencesProvider)[_key] = jsonEncode([for (final t in tasks ?? state) t.toJson()]);

  ScheduledTask? byId(String id) => state.where((t) => t.id == id).firstOrNull;

  ScheduledTask newTask({
    required String name,
    required String projectId,
    required String prompt,
    required Schedule schedule,
    String harness = everyaiHarnessName,
    String model = '',
    String effort = '',
    required AgentMode mode,
  }) => ScheduledTask(
    id: const Uuid().v7(),
    name: name,
    projectId: projectId,
    prompt: prompt,
    schedule: schedule,
    harness: harness,
    model: model,
    effort: effort,
    mode: mode,
  );

  /// Adds [task] or replaces the one with its id; an enabled task gets its next run from now.
  void put(ScheduledTask task) {
    final now = ref.read(scheduleClockProvider)();
    // The last run is the runner's: a form opened before it finished must not bring back an older one.
    final old = byId(task.id);
    final planned = task.copyWith(
      nextRun: task.enabled ? task.schedule.next(now) : null,
      lastRun: old?.lastRun ?? task.lastRun,
      lastSessionId: old == null ? task.lastSessionId : old.lastSessionId,
      lastError: old == null ? task.lastError : old.lastError,
    );
    missed = {...missed}..remove(task.id);
    state = state.any((t) => t.id == task.id)
        ? [for (final t in state) t.id == task.id ? planned : t]
        : [...state, planned];
    _save();
  }

  void setEnabled(String id, bool on) {
    if (byId(id) case final t?) put(t.copyWith(enabled: on));
  }

  void remove(String id) {
    missed = {...missed}..remove(id);
    state = [
      for (final t in state)
        if (t.id != id) t,
    ];
    _save();
  }

  /// Changes the task [id] as it is now (it may have been edited or removed meanwhile); no-op when gone.
  void patch(String id, ScheduledTask Function(ScheduledTask) change) {
    state = [for (final t in state) t.id == id ? change(t) : t];
    _save();
  }
}

/// The scheduled-task runner: looks for due tasks on a timer and starts their sessions. The ids it is
/// starting are its state. Tasks run only while the app is open.
final scheduleRunnerProvider = NotifierProvider<ScheduleRunner, Set<String>>(ScheduleRunner.new);

final class ScheduleRunner extends Notifier<Set<String>> {
  /// Task id → the session its last run in this app run started.
  final _started = <String, String>{};
  bool _ticking = false;

  /// A run later than this after its time counts as missed (a few ticks of slack).
  static const missedAfter = Duration(minutes: 3);

  @override
  Set<String> build() {
    final every = ref.read(scheduleTickProvider);
    if (every != null) {
      final timer = Timer.periodic(every, (_) => unawaited(tick()));
      ref.onDispose(timer.cancel);
    }
    // Loads the list, which works out what was missed.
    ref.read(scheduledTasksProvider);
    return const {};
  }

  /// Runs every enabled task that is due.
  Future<void> tick() async {
    if (_ticking) return;
    _ticking = true;
    try {
      final tasks = ref.read(scheduledTasksProvider.notifier);
      final now = ref.read(scheduleClockProvider)();
      for (final id in [for (final t in ref.read(scheduledTasksProvider)) t.id]) {
        // Read again: an earlier start can take a while, and the task may have been edited or removed since.
        final t = tasks.byId(id);
        if (t == null || !t.enabled || t.nextRun == null || t.nextRun!.isAfter(now)) continue;
        if (now.difference(t.nextRun!) > missedAfter) {
          // Due long ago (the computer slept): offer Run now, as after a restart, instead of starting by itself.
          tasks.missed = {...tasks.missed, id: t.nextRun!};
          tasks.patch(id, (t) => t.copyWith(nextRun: t.schedule.next(now)));
          continue;
        }
        await _run(t, now, scheduled: true);
      }
    } finally {
      _ticking = false;
    }
  }

  /// Runs the task [id] now, enabled or not; its schedule is untouched.
  Future<void> runNow(String id) async {
    if (ref.read(scheduledTasksProvider.notifier).byId(id) case final t?) {
      await _run(t, ref.read(scheduleClockProvider)(), scheduled: false);
    }
  }

  Future<void> _run(ScheduledTask task, DateTime now, {required bool scheduled}) async {
    final tasks = ref.read(scheduledTasksProvider.notifier);
    // The next run is set before anything starts, so a slow start can't fire it a second time.
    if (scheduled) tasks.patch(task.id, (t) => t.copyWith(nextRun: t.schedule.next(now)));
    if (state.contains(task.id)) return;
    if (_started[task.id] case final sid? when ref.read(scheduleSessionActiveProvider)(sid)) {
      tasks.patch(task.id, (t) => t.copyWith(lastError: 'Skipped: the last run is still working.'));
      return;
    }
    state = {...state, task.id};
    final notify = ref.read(systemNotifierProvider);
    try {
      final info = await ref.read(scheduleStarterProvider)(task);
      _started[task.id] = info.id;
      tasks.patch(task.id, (t) => t.copyWith(lastRun: now, lastSessionId: info.id, lastError: null));
      tasks.missed = {...tasks.missed}..remove(task.id);
      unawaited(notify.show('Scheduled task started', task.name));
    } on Object catch (e) {
      final why = e is HarnessError ? e.message : '$e';
      tasks.patch(task.id, (t) => t.copyWith(lastRun: now, lastError: why));
      unawaited(notify.show("Scheduled task didn't start", '${task.name}: $why'));
    } finally {
      state = {...state}..remove(task.id);
    }
  }
}
