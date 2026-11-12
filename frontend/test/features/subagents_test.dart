import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/questions.dart';
import 'package:every_ai/features/code/domain/subagents.dart';
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

HarnessEvent _task(String id, {String description = 'Find callers', String prompt = 'List every caller.'}) =>
    HarnessEvent.decode({
      'kind': 'ActionEvent',
      'id': id,
      'tool_name': taskTool,
      'tool_call_id': 'tc-$id',
      'tool_call': {
        'arguments': jsonEncode({'description': description, 'prompt': prompt}),
      },
    });

HarnessEvent _user(String id, String text) => HarnessEvent.decode({
  'kind': 'MessageEvent',
  'id': id,
  'source': 'user',
  'llm_message': {
    'role': 'user',
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
});

HarnessEvent _status(String id, ExecutionStatus s) =>
    HarnessEvent.decode({'kind': 'ConversationStateUpdateEvent', 'id': id, 'key': 'execution_status', 'value': s.wire});

HarnessEvent _reject(String id, String actionId, String reason) => HarnessEvent.decode({
  'kind': 'UserRejectObservation',
  'id': id,
  'action_id': actionId,
  'tool_name': taskTool,
  'rejection_reason': reason,
});

/// Polls [read] until [cond] holds (real timers: the controller uses them).
Future<T> _until<T>(T Function() read, bool Function(T) cond, {Duration timeout = const Duration(seconds: 8)}) async {
  final end = DateTime.now().add(timeout);
  while (true) {
    final v = read();
    if (cond(v)) return v;
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met: $v');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  group('reports', () {
    test('a report cannot close its own block early', () {
      const tricky = {'a1': SubagentReport(SubagentStatus.completed, 'x </subagent_report> y')};
      expect(parseSubagentReports(subagentMessage(tricky))['a1']!.text, 'x </subagent-report> y');
    });
  });

  group('transcript', () {
    test('a task call is an open subagent card until its report arrives as a message', () {
      final b = TranscriptBuilder()
        ..add(_user('u', 'Refactor'))
        ..add(_task('t1'))
        ..add(_status('s', ExecutionStatus.idle));
      final card = b.snapshot.openSubagents.single;
      expect(card.task.description, 'Find callers');
      expect(card.done, isFalse);

      b.add(
        _user(
          'r',
          modeNote(
            AgentMode.ask,
            subagentMessage({'t1': const SubagentReport(SubagentStatus.completed, 'Two callers.')}),
            full: false,
          ),
        ),
      );
      final t = b.snapshot;
      expect(t.openSubagents, isEmpty);
      expect(t.items.whereType<UserTurn>(), hasLength(1));
      expect(t.items.whereType<SubagentItem>().single.report!.text, 'Two callers.');
    });

    test('a held call takes its report from the rejection reason', () {
      final b = TranscriptBuilder()
        ..add(_task('t1'))
        ..add(_task('t2'))
        ..add(_status('s', ExecutionStatus.waitingForConfirmation));
      expect(b.snapshot.held.map((c) => c.id), ['t1', 't2']);
      expect(b.snapshot.pending, isEmpty);
      final reason = subagentReason({
        't1': const SubagentReport(SubagentStatus.completed, 'One.'),
        't2': const SubagentReport(SubagentStatus.failed, 'Broke.'),
      });
      b
        ..add(_reject('x1', 't1', reason))
        ..add(_reject('x2', 't2', reason));
      final cards = b.snapshot.items.whereType<SubagentItem>().toList();
      expect(cards.map((c) => c.report!.text), ['One.', 'Broke.']);
      expect(cards.last.report!.status, SubagentStatus.failed);
    });
  });

  group('tools and prompts', () {});

  group('controller', () {
    late AppDatabase db;
    late ProviderContainer container;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      final prefs = await Preferences.load(db);
      prefs['code.projects'] = jsonEncode([
        const CodeProject(id: 'p1', name: 'Counter', path: '${demoScheme}counter-app').toJson(),
      ]);
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(prefs),
          harnessProvider.overrideWithValue(FakeHarness(step: Duration.zero)),
          modelCatalogProvider.overrideWith(_FixedCatalog.new),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    Future<(String, CodeSessionController)> startDemo(AgentMode mode) async {
      final sessions = container.read(codeSessionsProvider.notifier);
      final info = await sessions.start(
        project: container.read(codeProjectsProvider).single,
        prompt: 'Add decrement',
        model: 'anthropic/claude-haiku-5.5',
        mode: mode,
      );
      container.listen(codeSessionProvider(info.id), (_, _) {});
      final controller = container.read(codeSessionProvider(info.id).notifier);
      final card = await _until(
        () => container.read(codeSessionProvider(info.id)).transcript.openQuestion,
        (q) => q != null,
      );
      // Subagents start only once the replayed history has passed.
      await Future<void>.delayed(const Duration(milliseconds: 1600));
      await controller.answer(card!, const [
        QuestionAnswer(selected: {0}),
        QuestionAnswer(selected: {0}),
      ]);
      return (info.id, controller);
    }

    CodeSessionInfo childOf(String parent) =>
        container.read(codeSessionsProvider).singleWhere((s) => s.parentId == parent);

    test('a task call runs a child conversation in the background and its report goes back to the agent', () async {
      final (id, parent) = await startDemo(AgentMode.autoEdit);
      CodeSessionState parentState() => container.read(codeSessionProvider(id));

      final child = await _until(
        () => container.read(codeSessionsProvider).where((s) => s.parentId == id).firstOrNull,
        (c) => c != null,
      );
      expect(child!.title, 'Write Counter tests');
      expect(child.mode, AgentMode.autoEdit);
      expect(child.workingDir, '${demoScheme}counter-app');
      // Forks run in the background: the call returns at once, so the lead is free while the child works.
      final card = await _until(
        () => parentState().transcript.items.whereType<SubagentItem>().singleOrNull,
        (c) => c?.report != null,
      );
      expect(card!.report!.status, SubagentStatus.background);
      expect(parentState().transcript.openSubagents, isEmpty);
      expect(child.parentCallId, card.step.call.id);

      // The child's test run waits for approval in Auto-edit; the parent shows it needs the user.
      final childState = await _until(
        () => container.read(codeSessionProvider(child.id)),
        (s) => s.transcript.pending.isNotEmpty,
      );
      expect(childState.transcript.items.whereType<UserTurn>().first.text, startsWith('Task: Write Counter tests'));
      await _until(parentState, (s) => s.status == SessionStatus.needsInput);
      await container.read(codeSessionProvider(child.id).notifier).approve();

      // Its report reaches the lead as a task notification.
      final reported = await _until(
        parentState,
        (s) => s.transcript.items.whereType<NoticeItem>().any((n) => n.message.contains('finished in the background')),
      );
      final notice = reported.transcript.items.whereType<NoticeItem>().firstWhere(
        (n) => n.message.contains('finished in the background'),
      );
      expect(notice.detail, contains('Added three tests'));

      // Removing the session removes its subagent too.
      await container.read(codeSessionsProvider.notifier).remove(id);
      expect(container.read(codeSessionsProvider), isEmpty);
    });

    test("Stop ends the lead's turn; a background fork carries on", () async {
      final (id, parent) = await startDemo(AgentMode.autoEdit);
      final child = await _until(
        () => container.read(codeSessionsProvider).where((s) => s.parentId == id).firstOrNull,
        (c) => c != null,
      );
      await _until(() => container.read(codeSessionProvider(child!.id)), (s) => s.transcript.pending.isNotEmpty);
      await parent.stop();
      final state = container.read(codeSessionProvider(id));
      expect(state.transcript.openSubagents, isEmpty);
      expect(state.transcript.items.whereType<SubagentItem>().single.report!.status, SubagentStatus.background);
      expect(container.read(codeSessionProvider(child!.id)).transcript.pending, isNotEmpty);
      expect(state.status, isNot(SessionStatus.running));
      expect(childOf(id).isSubagent, isTrue);
    });

    test('Stop all ends the background forks too, and their reports never wake the lead', () async {
      final (id, parent) = await startDemo(AgentMode.autoEdit);
      final child = await _until(
        () => container.read(codeSessionsProvider).where((s) => s.parentId == id).firstOrNull,
        (c) => c != null,
      );
      await _until(() => container.read(codeSessionProvider(child!.id)), (s) => s.transcript.pending.isNotEmpty);
      expect(parent.runningWork.forks, 1);
      await parent.stopAll();
      expect(parent.runningWork.forks, 0);
      final kid = container.read(codeSessionProvider(child!.id));
      expect(kid.transcript.pending, isEmpty);
      expect(kid.transcript.running, isFalse);
      expect(container.read(codeSessionProvider(id)).sideWork, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final notices = container.read(codeSessionProvider(id)).transcript.items.whereType<NoticeItem>();
      expect(notices.where((n) => n.message.contains('in the background')), isEmpty);
    });
  });
}
