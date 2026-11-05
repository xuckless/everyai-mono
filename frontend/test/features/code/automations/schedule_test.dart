import 'dart:convert';

import 'package:every_ai/features/code/automations/schedule.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('presets are cron strings with a plain label', () {
    expect(Schedule.daily(9, 5).cron, '5 9 * * *');
    expect(Schedule.daily(9, 5).label, 'Every day at 09:05');
    expect(Schedule.weekdays(18, 0).cron, '0 18 * * 1-5');
    expect(Schedule.weekdays(18, 0).label, 'Weekdays at 18:00');
    expect(Schedule.custom(' */5 * * * * ').label, 'Cron: */5 * * * *');
    expect(Schedule.custom('nope').problem, isNotNull);
    expect(Schedule.custom('nope').next(DateTime(2026)), isNull);
  });

  test('every N hours counts from the last run', () {
    final s = Schedule.everyHours(5);
    expect(s.next(DateTime.utc(2026, 11, 5, 22, 7)), DateTime.utc(2026, 11, 6, 3, 7));
    expect(s.label, 'Every 5 hours');
    expect(Schedule.everyHours(0).hours, 1);
  });

  test('upcoming lists the next runs in order', () {
    expect(Schedule.daily(9, 0).upcoming(DateTime(2026, 11, 5, 10), 3), [
      DateTime(2026, 11, 6, 9),
      DateTime(2026, 11, 7, 9),
      DateTime(2026, 11, 8, 9),
    ]);
  });

  test('a task survives JSON', () {
    final t = ScheduledTask(
      id: 'a',
      name: 'Triage',
      projectId: 'p',
      prompt: 'Look at the failing tests',
      schedule: Schedule.weekdays(8, 30),
      harness: 'codex',
      model: 'm',
      mode: AgentMode.plan,
      enabled: false,
      nextRun: DateTime.utc(2026, 11, 6, 8, 30),
      lastRun: DateTime.utc(2026, 11, 5, 8, 30),
      lastSessionId: 's',
      lastError: 'no',
    );
    final back = ScheduledTask.fromJson(jsonDecode(jsonEncode(t.toJson())) as Map<String, Object?>);
    expect(back.toJson(), t.toJson());
    expect(back.schedule, t.schedule);
    expect(back.mode, AgentMode.plan);
    expect(t.copyWith(lastError: null).lastError, isNull);
  });
}
