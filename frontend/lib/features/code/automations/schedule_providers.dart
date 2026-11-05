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
      (id) => switch (ref.read(codeSessionProvider(id)).status) {
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
    try {
      for (final j in jsonDecode(raw) as List<Object?>) {
        var t = ScheduledTask.fromJson(j! as Map<String, Object?>);
        if (t.enabled && (t.nextRun == null || !t.nextRun!.isAfter(now))) {
          if (t.nextRun != null) missed[t.id] = t.nextRun!;
          t = t.copyWith(nextRun: t.schedule.next(now));
        }
        tasks.add(t);
      }
    } on Object {
      // A damaged list: start with none rather than fail the app.
    }
    this.missed = missed;
    ref.read(preferencesProvider)[_key] = jsonEncode([for (final t in tasks) t.toJson()]);
    return tasks;
  }

  void _save() => ref.read(preferencesProvider)[_key] = jsonEncode([for (final t in state) t.toJson()]);

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
    final planned = task.copyWith(nextRun: task.enabled ? task.schedule.next(now) : null);
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
    final now = ref.read(scheduleClockProvider)();
    for (final t in ref.read(scheduledTasksProvider)) {
      if (t.enabled && t.nextRun != null && !t.nextRun!.isAfter(now)) await _run(t, now, scheduled: true);
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
      if (scheduled) tasks.patch(task.id, (t) => t.copyWith(lastError: 'Skipped: the last run is still working.'));
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
