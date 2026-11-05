import 'dart:convert';

import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/features/code/automations/schedule.dart';
import 'package:every_ai/features/code/automations/schedule_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/harness/harness.dart' show HarnessError;
import 'package:every_ai/features/code/session_notifications.dart' show SystemNotifier, systemNotifierProvider;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Notices implements SystemNotifier {
  final shown = <(String, String)>[];

  @override
  Future<void> show(String title, String body) async => shown.add((title, body));
}

CodeSessionInfo _info(String id) => CodeSessionInfo(
  id: id,
  projectId: 'p',
  title: 't',
  conversationId: 'c',
  model: 'm',
  mode: AgentMode.ask,
  workingDir: '/x',
  createdAt: DateTime(2026),
);

ScheduledTask _task({String id = 'a', bool enabled = true, DateTime? nextRun}) => ScheduledTask(
  id: id,
  name: 'Daily triage',
  projectId: 'p',
  prompt: 'Triage',
  schedule: Schedule.daily(9, 0),
  enabled: enabled,
  nextRun: nextRun,
);

final class _Rig {
  _Rig({List<ScheduledTask> stored = const [], DateTime? now}) : now = now ?? DateTime(2026, 11, 5, 8, 0) {
    final prefs = Preferences.inMemory({
      if (stored.isNotEmpty) 'code.schedules': jsonEncode([for (final t in stored) t.toJson()]),
    });
    this.prefs = prefs;
    container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        scheduleClockProvider.overrideWithValue(_nowNow),
        scheduleTickProvider.overrideWithValue(null),
        systemNotifierProvider.overrideWithValue(notices),
        scheduleStarterProvider.overrideWithValue((task) async {
          started.add(task);
          // What the task said when it was dispatched.
          plannedAtStart.add(tasks.byId(task.id)?.nextRun);
          if (failWith != null) throw failWith!;
          return _info('s${started.length}');
        }),
        scheduleSessionActiveProvider.overrideWithValue(active.contains),
      ],
    );
  }

  DateTime now;
  DateTime _nowNow() => now;
  late final Preferences prefs;
  late final ProviderContainer container;
  final notices = _Notices();
  final started = <ScheduledTask>[];
  final plannedAtStart = <DateTime?>[];
  final active = <String>{};
  Object? failWith;

  ScheduledTasks get tasks => container.read(scheduledTasksProvider.notifier);
  ScheduleRunner get runner => container.read(scheduleRunnerProvider.notifier);
  ScheduledTask task(String id) => tasks.byId(id)!;
}

void main() {
  test('a due task starts once and its next run moves on before it dispatches', () async {
    final rig = _Rig();
    rig.tasks.put(_task());
    expect(rig.task('a').nextRun, DateTime(2026, 11, 5, 9));
    rig.now = DateTime(2026, 11, 5, 9, 0, 20);
    await rig.runner.tick();
    await rig.runner.tick();
    expect(rig.started.map((t) => t.id), ['a']);
    expect(rig.plannedAtStart.single, DateTime(2026, 11, 6, 9));
    expect(rig.task('a').lastSessionId, 's1');
    expect(rig.task('a').lastRun, rig.now);
    expect(rig.task('a').lastError, isNull);
    expect(rig.notices.shown.single, ('Scheduled task started', 'Daily triage'));
  });

  test('a task that is not due, or is off, does not start', () async {
    final rig = _Rig();
    rig.tasks.put(_task());
    rig.tasks.put(_task(id: 'b', enabled: false));
    expect(rig.task('b').nextRun, isNull);
    await rig.runner.tick();
    expect(rig.started, isEmpty);
    rig.now = DateTime(2026, 11, 5, 10);
    await rig.runner.tick();
    expect(rig.started.map((t) => t.id), ['a']);
  });

  test('a long sleep fires once, then plans the next day', () async {
    final rig = _Rig();
    rig.tasks.put(_task());
    rig.now = DateTime(2026, 11, 9, 15);
    await rig.runner.tick();
    await rig.runner.tick();
    expect(rig.started, hasLength(1));
    expect(rig.task('a').nextRun, DateTime(2026, 11, 10, 9));
  });

  test('a previous run that is still working is skipped', () async {
    final rig = _Rig();
    rig.tasks.put(_task());
    rig.now = DateTime(2026, 11, 5, 9);
    await rig.runner.tick();
    rig.active.add('s1');
    rig.now = DateTime(2026, 11, 6, 9);
    await rig.runner.tick();
    expect(rig.started, hasLength(1));
    expect(rig.task('a').lastError, contains('still working'));
    expect(rig.task('a').nextRun, DateTime(2026, 11, 7, 9));
    rig.active.clear();
    rig.now = DateTime(2026, 11, 7, 9);
    await rig.runner.tick();
    expect(rig.started, hasLength(2));
    expect(rig.task('a').lastError, isNull);
  });

  test('a start that fails is kept on the task and notified', () async {
    final rig = _Rig()..failWith = const HarnessError('Turn on Claude Code in Settings first.');
    rig.tasks.put(_task());
    rig.now = DateTime(2026, 11, 5, 9);
    await rig.runner.tick();
    expect(rig.task('a').lastError, 'Turn on Claude Code in Settings first.');
    expect(rig.task('a').lastSessionId, isNull);
    expect(rig.task('a').nextRun, DateTime(2026, 11, 6, 9));
    expect(rig.notices.shown.single.$1, "Scheduled task didn't start");
    expect(rig.notices.shown.single.$2, contains('Turn on Claude Code'));
  });

  test('on load a past run is marked missed, not run, and the next run is planned', () async {
    final rig = _Rig(
      stored: [_task(nextRun: DateTime(2026, 11, 4, 9))],
      now: DateTime(2026, 11, 5, 8),
    );
    expect(rig.task('a').nextRun, DateTime(2026, 11, 5, 9));
    expect(rig.tasks.missed, {'a': DateTime(2026, 11, 4, 9)});
    await rig.runner.tick();
    expect(rig.started, isEmpty);
    // The fixed plan was saved.
    expect(rig.prefs['code.schedules'], contains('2026-11-05T09:00:00'));
  });

  test('run now works on a disabled task and clears the missed mark', () async {
    final rig = _Rig(stored: [_task(enabled: false)]);
    await rig.runner.runNow('a');
    expect(rig.started, hasLength(1));
    expect(rig.task('a').enabled, isFalse);
    expect(rig.task('a').nextRun, isNull);
    expect(rig.task('a').lastSessionId, 's1');

    final late = _Rig(stored: [_task(nextRun: DateTime(2026, 11, 4, 9))]);
    expect(late.tasks.missed, isNotEmpty);
    await late.runner.runNow('a');
    expect(late.tasks.missed, isEmpty);
    expect(late.task('a').nextRun, DateTime(2026, 11, 5, 9));
  });

  test('editing a task replans it from now', () {
    final rig = _Rig();
    rig.tasks.put(_task());
    rig.tasks.put(rig.task('a').copyWith(schedule: Schedule.everyHours(2)));
    expect(rig.task('a').nextRun, DateTime(2026, 11, 5, 10));
    rig.tasks.setEnabled('a', false);
    expect(rig.task('a').nextRun, isNull);
    rig.tasks.remove('a');
    expect(rig.tasks.byId('a'), isNull);
  });
}
