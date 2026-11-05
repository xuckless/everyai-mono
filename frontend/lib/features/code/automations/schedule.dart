import 'package:flutter/foundation.dart';

import '../domain/agent_mode.dart';
import '../domain/code_session.dart' show everyaiHarnessName;
import 'cron.dart';

/// When a task runs: a cron expression (the presets are written as one), or every [hours] hours.
@immutable
final class Schedule {
  const Schedule._({this.cron, this.hours});

  /// Every day at [hour]:[minute].
  factory Schedule.daily(int hour, int minute) => Schedule._(cron: '$minute $hour * * *');

  /// Monday to Friday at [hour]:[minute].
  factory Schedule.weekdays(int hour, int minute) => Schedule._(cron: '$minute $hour * * 1-5');

  /// Every [hours] hours from the last run (not on the clock hour, so it doesn't drift at midnight).
  factory Schedule.everyHours(int hours) => Schedule._(hours: hours < 1 ? 1 : hours);

  Schedule.custom(String cron) : this._(cron: cron.trim());

  final String? cron;
  final int? hours;

  /// Why this can't run, or null.
  String? get problem => cron == null ? null : CronSpec.problem(cron!);

  /// The first run after [after], null when there is none.
  DateTime? next(DateTime after) {
    if (hours case final h?) return after.add(Duration(hours: h));
    final c = cron;
    if (c == null || CronSpec.problem(c) != null) return null;
    return CronSpec.parse(c).next(after);
  }

  /// The next [n] runs after [after].
  List<DateTime> upcoming(DateTime after, int n) {
    final out = <DateTime>[];
    for (var t = next(after); t != null && out.length < n; t = next(t)) {
      out.add(t);
    }
    return out;
  }

  String get label {
    if (hours case final h?) return h == 1 ? 'Every hour' : 'Every $h hours';
    final m = RegExp(r'^(\d+) (\d+) \* \* (\*|1-5)$').firstMatch(cron ?? '');
    if (m != null) {
      final time = '${m[2]!.padLeft(2, '0')}:${m[1]!.padLeft(2, '0')}';
      return m[3] == '*' ? 'Every day at $time' : 'Weekdays at $time';
    }
    return 'Cron: $cron';
  }

  Map<String, Object?> toJson() => {'cron': ?cron, 'hours': ?hours};

  factory Schedule.fromJson(Map<String, Object?> json) =>
      json['hours'] is int ? Schedule.everyHours(json['hours']! as int) : Schedule.custom('${json['cron'] ?? ''}');

  @override
  bool operator ==(Object other) => other is Schedule && other.cron == cron && other.hours == hours;

  @override
  int get hashCode => Object.hash(cron, hours);
}

/// One scheduled task: what to start, where, and when. It starts a normal Code session.
@immutable
final class ScheduledTask {
  const ScheduledTask({
    required this.id,
    required this.name,
    required this.projectId,
    required this.prompt,
    required this.schedule,
    this.harness = everyaiHarnessName,
    this.model = '',
    this.effort = '',
    this.mode = AgentMode.ask,
    this.enabled = true,
    this.nextRun,
    this.lastRun,
    this.lastSessionId,
    this.lastError,
  });

  final String id;
  final String name;
  final String projectId;
  final String prompt;
  final Schedule schedule;

  /// The lead (`DriverInfo.id`).
  final String harness;

  /// '' = the model currently picked for that lead.
  final String model;
  final String effort;
  final AgentMode mode;
  final bool enabled;

  /// The next planned start; moved on before a run is dispatched, so a run never fires twice.
  final DateTime? nextRun;
  final DateTime? lastRun;
  final String? lastSessionId;

  /// Why the last run didn't start, or null.
  final String? lastError;

  static const _keep = Object();

  ScheduledTask copyWith({
    String? name,
    String? projectId,
    String? prompt,
    Schedule? schedule,
    String? harness,
    String? model,
    String? effort,
    AgentMode? mode,
    bool? enabled,
    Object? nextRun = _keep,
    Object? lastRun = _keep,
    Object? lastSessionId = _keep,
    Object? lastError = _keep,
  }) => ScheduledTask(
    id: id,
    name: name ?? this.name,
    projectId: projectId ?? this.projectId,
    prompt: prompt ?? this.prompt,
    schedule: schedule ?? this.schedule,
    harness: harness ?? this.harness,
    model: model ?? this.model,
    effort: effort ?? this.effort,
    mode: mode ?? this.mode,
    enabled: enabled ?? this.enabled,
    nextRun: identical(nextRun, _keep) ? this.nextRun : nextRun as DateTime?,
    lastRun: identical(lastRun, _keep) ? this.lastRun : lastRun as DateTime?,
    lastSessionId: identical(lastSessionId, _keep) ? this.lastSessionId : lastSessionId as String?,
    lastError: identical(lastError, _keep) ? this.lastError : lastError as String?,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'projectId': projectId,
    'prompt': prompt,
    'schedule': schedule.toJson(),
    'harness': harness,
    'model': model,
    'effort': effort,
    'mode': mode.name,
    'enabled': enabled,
    'nextRun': ?nextRun?.toIso8601String(),
    'lastRun': ?lastRun?.toIso8601String(),
    'lastSessionId': ?lastSessionId,
    'lastError': ?lastError,
  };

  factory ScheduledTask.fromJson(Map<String, Object?> json) => ScheduledTask(
    id: json['id']! as String,
    name: json['name']! as String,
    projectId: json['projectId']! as String,
    prompt: json['prompt']! as String,
    schedule: Schedule.fromJson(json['schedule']! as Map<String, Object?>),
    harness: json['harness'] as String? ?? everyaiHarnessName,
    model: json['model'] as String? ?? '',
    effort: json['effort'] as String? ?? '',
    mode: AgentMode.values.asNameMap()[json['mode']] ?? AgentMode.ask,
    enabled: json['enabled'] as bool? ?? true,
    nextRun: DateTime.tryParse('${json['nextRun']}'),
    lastRun: DateTime.tryParse('${json['lastRun']}'),
    lastSessionId: json['lastSessionId'] as String?,
    lastError: json['lastError'] as String?,
  );
}
