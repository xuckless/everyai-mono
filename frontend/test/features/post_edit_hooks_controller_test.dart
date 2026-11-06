import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/code/checks/post_edit_hooks_provider.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
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

  setUp(() async {
    notes.clear();
    calls = 0;
    skips = '';
    gate = null;
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
            turns: [
              [_agent('reply one')],
              [_agent('reply two')],
              [_agent('reply three')],
              [_agent('reply four')],
            ],
          ),
        ),
        modelCatalogProvider.overrideWith(_FixedCatalog.new),
        postEditHooksProvider.overrideWithValue((
          info, {
          required shellDir,
          required refusal,
          required autoFormat,
        }) async {
          calls++;
          await gate?.future;
          return (report: notes.isEmpty ? '' : notes.removeAt(0), skipped: skips, tree: 'tree-$calls');
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

  test('the snapshot and a waiting report are kept with the session; skips are shown once', () async {
    final controller = await open();
    final sessions = container.read(codeSessionsProvider.notifier);
    await _until(() => saidBy(controller), (s) => s.contains('agent:reply one'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    notes.add(_report);
    skips = 'Skipped: ruff (not installed)';
    final before = calls;
    await controller.send('second');
    await _until(() => calls, (n) => n == before + 1);
    final id = controller.sessionId;
    await _until(() => sessions.byId(id)!.pendingChecks, (p) => p == _report);
    final info = sessions.byId(id)!;
    expect(info.checkedTree, 'tree-${before + 1}');
    // A restart reads them back.
    final back = CodeSessionInfo.fromJson(info.toJson());
    expect(back.pendingChecks, _report);
    expect(back.checkedTree, info.checkedTree);
    List<NoticeItem> skipped() => [
      for (final n in controller.state.transcript.items.whereType<NoticeItem>())
        if (n.message == checksSkippedNotice) n,
    ];
    expect(skipped().single.detail, skips);

    await controller.send('third');
    await _until(() => calls, (n) => n == before + 2);
    await _until(() => saidBy(controller), (s) => s.contains('agent:reply three'));
    expect(sessions.byId(id)!.pendingChecks, '');
    // The same skips again: not shown again.
    expect(skipped(), hasLength(1));
  });

  test('a failing check at turn end goes first in the next message; a clean one adds nothing', () async {
    final info = await container
        .read(codeSessionsProvider.notifier)
        .start(
          project: container.read(codeProjectsProvider).single,
          prompt: 'first',
          model: 'anthropic/claude-haiku-5.5',
          mode: AgentMode.fullAuto,
        );
    final id = info.id;
    container.listen(codeSessionProvider(id), (_, _) {});
    final controller = container.read(codeSessionProvider(id).notifier);
    Transcript t() => controller.state.transcript;
    List<String> said() => [
      for (final item in t().items)
        if (item is UserTurn) 'user:${item.text}' else if (item is AgentText) 'agent:${item.text}',
    ];
    List<String> sent() => [
      for (final e in controller.mirrorEvents)
        if (e is ChatMessage && e.fromUser) e.text,
    ];

    await _until(said, (s) => s.contains('agent:reply one'));
    // Turn two's checks fail.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    notes.addAll([_report, '']);
    final before = calls;
    await controller.send('second');
    await _until(said, (s) => s.contains('agent:reply two'));
    await _until(() => calls, (n) => n == before + 1);
    await controller.send('third');
    await _until(said, (s) => s.contains('agent:reply three'));
    final third = sent().firstWhere((m) => m.contains('third'));
    expect(third, contains(_report));
    expect(third.indexOf(_report), lessThan(third.indexOf('third')));
    // The user's bubble shows their words; the report is its own row.
    expect(said(), contains('user:third'));
    final row = t().items.whereType<NoticeItem>().where((n) => n.message == checksNotice).single;
    expect(row.detail, contains('lib/a.dart'));

    // Turn three's checks are clean: the next message carries no report.
    await _until(() => calls, (n) => n == before + 2);
    await controller.send('fourth');
    await _until(said, (s) => s.contains('agent:reply four'));
    expect(sent().firstWhere((m) => m.contains('fourth')), isNot(contains('<everyai-checks>')));
    expect(t().items.whereType<NoticeItem>().where((n) => n.message == checksNotice), hasLength(1));
  });
}
