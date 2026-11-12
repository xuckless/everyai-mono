import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/code/checks/post_edit_hooks.dart';
import 'package:every_ai/features/code/checks/post_edit_hooks_provider.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/rewind.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/fake_harness.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FixedCatalog extends CatalogController {
  @override
  ModelCatalog build() => builtInCatalog;
}

Future<T> _until<T>(T Function() read, bool Function(T) cond) async {
  final end = DateTime.now().add(const Duration(seconds: 8));
  while (true) {
    final v = read();
    if (cond(v)) return v;
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met: $v');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Map<String, Object?> _agent(String text) => {
  'kind': 'MessageEvent',
  'source': 'agent',
  'llm_message': {
    'role': 'assistant',
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
};

const _report = '<everyai-checks>\nlib/a.dart\n  dart analyze: error - lib/a.dart:1:1 - bad\n</everyai-checks>';

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  final notes = <String>[];
  var calls = 0;
  var skips = '';
  Completer<void>? gate;
  var cancelled = 0;
  late List<List<Map<String, Object?>>> turns;
  // The slow checks: the runs the next fast round hands over, the reports they give, and their gate.
  var slowRuns = <HookRun>[];
  final slowNotes = <String>[];
  Completer<void>? slowGate;
  // Whether a subagent was still open when each round started.
  final openAtCall = <bool>[];
  bool Function()? onCall;

  setUp(() async {
    openAtCall.clear();
    onCall = null;
    notes.clear();
    calls = 0;
    skips = '';
    gate = null;
    cancelled = 0;
    slowRuns = [];
    slowNotes.clear();
    slowGate = null;
    turns = [
      [_agent('reply one')],
      [_agent('reply two')],
      [_agent('reply three')],
      [_agent('reply four')],
      [_agent('reply five')],
    ];
    CodeSessionController.liveAfter = Duration.zero;
    db = AppDatabase(NativeDatabase.memory());
    final prefs = await Preferences.load(db);
    prefs['code.projects'] = jsonEncode([
      const CodeProject(id: 'p1', name: 'Counter', path: '${demoScheme}counter-app').toJson(),
    ]);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(prefs),
        harnessProvider.overrideWithValue(
          FakeHarness(
            step: Duration.zero,
            turns: turns,
            subagentTurns: [
              [_agent('child report')],
            ],
          ),
        ),
        modelCatalogProvider.overrideWith(_FixedCatalog.new),
        postEditHooksProvider.overrideWithValue((
          info, {
          required shellDir,
          required refusal,
          required autoFormat,
          required touched,
          cancel,
        }) async {
          calls++;
          openAtCall.add(onCall?.call() ?? false);
          var stopped = false;
          unawaited(cancel?.then((_) => stopped = true));
          if (gate case final g?) await Future.any([g.future, ?cancel]);
          await Future<void>.delayed(Duration.zero);
          if (stopped) cancelled++;
          final slow = slowRuns;
          slowRuns = [];
          return (report: notes.isEmpty ? '' : notes.removeAt(0), skipped: skips, tree: 'tree-$calls', slow: slow);
        }),
        slowHooksProvider.overrideWithValue((
          info,
          runs, {
          required shellDir,
          required refusal,
          required baselines,
          cancel,
        }) async {
          if (slowGate case final g?) await Future.any([g.future, ?cancel]);
          return (report: slowNotes.isEmpty ? '' : slowNotes.removeAt(0), skipped: '');
        }),
      ],
    );
  });

  tearDown(() async {
    CodeSessionController.liveAfter = const Duration(milliseconds: 1500);
    container.dispose();
    await db.close();
  });

  Future<CodeSessionController> open() async {
    final info = await container
        .read(codeSessionsProvider.notifier)
        .start(
          project: container.read(codeProjectsProvider).single,
          prompt: 'first',
          model: 'anthropic/claude-haiku-5.5',
          mode: AgentMode.fullAuto,
        );
    container.listen(codeSessionProvider(info.id), (_, _) {});
    return container.read(codeSessionProvider(info.id).notifier);
  }

  List<String> saidBy(CodeSessionController c) => [
    for (final item in c.state.transcript.items)
      if (item is UserTurn) 'user:${item.text}' else if (item is AgentText) 'agent:${item.text}',
  ];
  List<String> sentBy(CodeSessionController c) => [
    for (final e in c.mirrorEvents)
      if (e is ChatMessage && e.fromUser) e.text,
  ];

  test('while the checks run, a message waits in the queue (shown) and goes once with their report', () async {
    final controller = await open();
    await _until(() => saidBy(controller), (s) => s.contains('agent:reply one'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    // Turn two's checks are slow and fail.
    gate = Completer<void>();
    notes.add(_report);
    final before = calls;
    await controller.send('second');
    await _until(() => saidBy(controller), (s) => s.contains('agent:reply two'));
    await _until(() => calls, (n) => n == before + 1);
    // Two messages while they run: both wait, visibly, and nothing reaches the lead.
    expect(await controller.send('third'), isTrue);
    expect(await controller.send('fourth'), isTrue);
    expect([for (final q in controller.state.queued) q.text], ['third', 'fourth']);
    final sentBefore = sentBy(controller).length;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(sentBy(controller), hasLength(sentBefore));
    gate!.complete();
    await _until(() => saidBy(controller), (s) => s.contains('agent:reply three'));
    final third = sentBy(controller).firstWhere((m) => m.contains('third'));
    expect(third, contains(_report));
    // The second one still waits for its own turn, behind the first.
    expect(third, isNot(contains('fourth')));
    await _until(() => saidBy(controller), (s) => s.contains('agent:reply four'));
    expect(saidBy(controller).indexOf('user:fourth'), greaterThan(saidBy(controller).indexOf('agent:reply three')));
  });

  test('Stop cancels the checks running; the next message goes at once, without their report', () async {
    final controller = await open();
    final sessions = container.read(codeSessionsProvider.notifier);
    await _until(() => saidBy(controller), (s) => s.contains('agent:reply one'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    gate = Completer<void>();
    notes.add(_report);
    final before = calls;
    await controller.send('second');
    await _until(() => calls, (n) => n == before + 1);
    final tree = sessions.byId(controller.sessionId)!.checkedTree;
    await controller.stop();
    await _until(() => cancelled, (n) => n == 1);
    await controller.send('third');
    await _until(() => saidBy(controller), (s) => s.contains('agent:reply three'));
    expect(sentBy(controller).firstWhere((m) => m.contains('third')), isNot(contains('<everyai-checks>')));
    // The cancelled round moved nothing: what it would have checked is checked next time.
    expect(sessions.byId(controller.sessionId)!.checkedTree, tree);
    expect(gate!.isCompleted, isFalse);
  });

  test('a rewind stops the checks running and drops the report about the turns it undoes', () async {
    final controller = await open();
    final sessions = container.read(codeSessionsProvider.notifier);
    await _until(() => saidBy(controller), (s) => s.contains('agent:reply one'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    notes.add(_report);
    final before = calls;
    await controller.send('second');
    await _until(() => sessions.byId(controller.sessionId)!.pendingChecks, (p) => p == _report);
    gate = Completer<void>();
    // A third turn whose checks still run when the user rewinds.
    turns[2] = [_agent('reply three')];
    await controller.send('third');
    await _until(() => calls, (n) => n == before + 2);
    final outcome = await controller.rewind(2);
    expect(outcome.kind, RewindKind.done);
    expect(cancelled, 1);
    expect(sessions.byId(controller.sessionId)!.pendingChecks, '');
    expect(gate!.isCompleted, isFalse);
    // The rewind's own stop started no new round.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(calls, before + 2);
  });
}
