import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:every_ai/core/net/api_client.dart';
import 'package:every_ai/features/usage/usage_totals.dart';
import 'package:every_ai/features/code/gateway_key.dart';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/harness/fake_harness.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/models/models_providers.dart';

import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/features/code/automations/schedule.dart';
import 'package:every_ai/features/code/automations/schedule_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/harness/harness.dart' show HarnessError;
import 'package:every_ai/features/code/session_notifications.dart' show SystemNotifier, systemNotifierProvider;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FixedCatalog extends CatalogController {
  @override
  ModelCatalog build() => builtInCatalog;
}

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
          onStart?.call(task);
          await holdStart;
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
  void Function(ScheduledTask)? onStart;
  Future<void>? holdStart;

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
    rig.now = DateTime(2026, 11, 5, 9, 1);
    await rig.runner.tick();
    expect(rig.started.map((t) => t.id), ['a']);
  });

  test('a run due long ago (the computer slept) is marked missed, not started', () async {
    final rig = _Rig();
    rig.tasks.put(_task());
    rig.now = DateTime(2026, 11, 9, 15);
    await rig.runner.tick();
    await rig.runner.tick();
    expect(rig.started, isEmpty);
    expect(rig.tasks.missed, {'a': DateTime(2026, 11, 5, 9)});
    expect(rig.task('a').nextRun, DateTime(2026, 11, 10, 9));
    // A little late (a few ticks) still runs.
    rig.now = DateTime(2026, 11, 10, 9, 2);
    await rig.runner.tick();
    expect(rig.started, hasLength(1));
  });

  test('a task removed or disabled while an earlier one starts is not started', () async {
    final rig = _Rig();
    rig.tasks.put(_task());
    rig.tasks.put(_task(id: 'b'));
    rig.tasks.put(_task(id: 'c'));
    rig.now = DateTime(2026, 11, 5, 9);
    rig.onStart = (task) {
      if (task.id == 'a') {
        rig.tasks.remove('b');
        rig.tasks.setEnabled('c', false);
      }
    };
    await rig.runner.tick();
    expect(rig.started.map((t) => t.id), ['a']);
  });

  test('a tick that overlaps a slow start does not start a task twice', () async {
    final rig = _Rig();
    rig.tasks.put(_task());
    rig.now = DateTime(2026, 11, 5, 9);
    final gate = Completer<void>();
    rig.holdStart = gate.future;
    final first = rig.runner.tick();
    await rig.runner.tick();
    gate.complete();
    await first;
    expect(rig.started, hasLength(1));
    expect(rig.task('a').lastError, isNull);
  });

  test('saving an edit keeps the last run the runner recorded meanwhile', () async {
    final rig = _Rig();
    rig.tasks.put(_task());
    final opened = rig.task('a');
    rig.now = DateTime(2026, 11, 5, 9);
    await rig.runner.tick();
    rig.tasks.put(opened.copyWith(prompt: 'Changed'));
    expect(rig.task('a').prompt, 'Changed');
    expect(rig.task('a').lastSessionId, 's1');
    expect(rig.task('a').lastRun, rig.now);
  });

  test('an entry this build cannot read is skipped and stays in the stored list', () {
    final good = jsonEncode(_task().toJson());
    final rig = _Rig();
    rig.prefs['code.schedules'] = '[$good,{"id":"x","schedule":"weekly"}]';
    final fresh = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(rig.prefs),
        scheduleClockProvider.overrideWithValue(() => rig.now),
      ],
    );
    addTearDown(fresh.dispose);
    expect(fresh.read(scheduledTasksProvider).map((t) => t.id), ['a']);
    expect(rig.prefs['code.schedules'], contains('"id":"x"'));
  });

  test('a session the runner started gets its controller; a status check builds none', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final dir = Directory.systemTemp.createTempSync('sched');
    addTearDown(() => dir.deleteSync(recursive: true));
    final prefs = await Preferences.load(db);
    prefs['code.projects'] = jsonEncode([CodeProject(id: 'p', name: 'Counter', path: dir.path).toJson()]);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(prefs),
        everyaiHarnessProvider.overrideWithValue(FakeHarness(step: Duration.zero, turns: const [[]])),
        modelCatalogProvider.overrideWith(_FixedCatalog.new),
        // No network: whatever reaches for the backend fails at once.
        apiClientProvider.overrideWithValue(
          ApiClient(
            baseUrl: Uri.parse('http://backend/'),
            client: MockClient((req) async => http.Response('no network in this test', 599)),
          ),
        ),
        gatewayKeysProvider.overrideWith((ref) => GatewayKeys(store: _MemoryStore(), mint: () async => 'sk-eai-test')),
        codeSideModelProvider.overrideWithValue((messages) async => ''),
        codeUsageProvider.overrideWithBuild((ref, n) async => UsageTotals.zero),
      ],
    );
    addTearDown(container.dispose);
    final start = Provider(
      (ref) =>
          (ScheduledTask t) => startTaskSession(ref, t),
    );
    expect(container.read(scheduleSessionActiveProvider)('nobody'), isFalse);
    expect(container.exists(codeSessionProvider('nobody')), isFalse);
    final info = await container.read(start)(_task().copyWith(mode: AgentMode.fullAuto));
    expect(container.exists(codeSessionProvider(info.id)), isTrue);
    expect(container.read(scheduleSessionActiveProvider)(info.id), isTrue);
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

final class _MemoryStore implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}
