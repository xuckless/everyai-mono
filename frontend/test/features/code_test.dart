import 'dart:async';

import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/questions.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/fake_harness.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:flutter_test/flutter_test.dart';

ActionCall _call(Map<String, Object?> action, {String tool = 'terminal'}) =>
    HarnessEvent.decode({'kind': 'ActionEvent', 'id': 'a', 'tool_name': tool, 'action': action}) as ActionCall;

SessionSpec _spec(AgentMode mode, [String? first = 'Add decrement']) => SessionSpec(
  workingDir: '/tmp/x',
  model: 'anthropic/claude-haiku-5.5',
  mode: mode,
  llmBaseUrl: '',
  llmApiKey: '',
  sessionTag: 's',
  initialMessage: first,
);

/// One subscription feeding a builder; [until] waits for a condition.
final class _Feed {
  _Feed(HarnessSession s) {
    _sub = s.events.listen((e) {
      builder.add(e);
      _check();
    });
  }

  final builder = TranscriptBuilder();
  late final StreamSubscription<HarnessEvent> _sub;
  bool Function(Transcript)? _cond;
  Completer<Transcript>? _done;

  void _check() {
    final cond = _cond;
    if (cond != null && cond(builder.snapshot)) {
      _cond = null;
      _done!.complete(builder.snapshot);
    }
  }

  Future<Transcript> until(bool Function(Transcript) cond) {
    _cond = cond;
    _done = Completer();
    _check();
    return _done!.future.timeout(const Duration(seconds: 5));
  }

  Future<void> cancel() => _sub.cancel();
}

void main() {
  group('events', () {
    test('decodes OpenHands frames tolerantly', () {
      final e = HarnessEvent.decodeFrame(
        '{"kind":"ActionEvent","id":"1","tool_name":"terminal","tool_call_id":"t","thought":[{"type":"text","text":"Hm"}],'
        '"action":{"kind":"TerminalAction","command":"ls"},"security_risk":"LOW","extra":42}',
      );
      expect(e, isA<ActionCall>().having((a) => a.str('command'), 'command', 'ls').having((a) => a.thought, 't', 'Hm'));
      final s = HarnessEvent.decode({
        'kind': 'ConversationStateUpdateEvent',
        'key': 'full_state',
        'value': {'execution_status': 'waiting_for_confirmation'},
      });
      expect((s as StateChange).executionStatus, ExecutionStatus.waitingForConfirmation);
      expect(HarnessEvent.decode({'kind': 'TokenEvent'}), isA<UnknownEvent>());
    });

    test('client tool arguments come from tool_call', () {
      final e = HarnessEvent.decode({
        'kind': 'ActionEvent',
        'tool_name': askUserQuestionTool,
        'tool_call': {'arguments': '{"questions":[{"question":"Q?","options":["A","B"]}]}'},
      }) as ActionCall;
      final qs = Question.listFrom(e.action);
      expect(qs.single.options.map((o) => o.label), ['A', 'B']);
    });
  });

  group('questions', () {
    const qs = [
      Question(question: 'Floor?', options: [QuestionOption('Zero', ''), QuestionOption('Throw', '')]),
      Question(
        question: 'Extras?',
        multiSelect: true,
        options: [QuestionOption('reset()', ''), QuestionOption('toString()', ''), QuestionOption('Docs', '')],
      ),
    ];

    test('answers round-trip through the message', () {
      final answers = [
        const QuestionAnswer(selected: {0}),
        const QuestionAnswer(selected: {2, 0}, other: 'and a test'),
      ];
      final text = answersMessage(qs, answers);
      expect(text, contains('1. Floor? → Zero'));
      expect(text, contains('2. Extras? → reset(), Docs, and a test'));
      expect(parseAnswers(text, qs), answers);
      expect(parseAnswers('Just a message', qs), isNull);
    });
  });

  group('modes', () {
    final view = _call({'kind': 'FileEditorAction', 'command': 'view', 'path': 'a'}, tool: 'file_editor');
    final edit = _call({'kind': 'FileEditorAction', 'command': 'str_replace', 'path': 'a'}, tool: 'file_editor');
    final ls = _call({'kind': 'TerminalAction', 'command': 'ls -la'});
    final sneaky = _call({'kind': 'TerminalAction', 'command': 'ls; rm -rf build'});
    final runTests = _call({'kind': 'TerminalAction', 'command': 'flutter test'});
    final ask = _call({}, tool: askUserQuestionTool);

    test('read-only detection refuses chained commands', () {
      expect(AgentMode.isReadOnly(ls), isTrue);
      expect(AgentMode.isReadOnly(sneaky), isFalse);
      expect(AgentMode.isReadOnly(view), isTrue);
      expect(AgentMode.isReadOnly(edit), isFalse);
    });

    test('each mode approves what it should', () {
      expect([view, edit, runTests, ask].map(AgentMode.ask.autoApproves), [true, false, false, true]);
      expect([view, edit, runTests, ask].map(AgentMode.autoEdit.autoApproves), [true, true, false, true]);
      expect([view, edit, runTests, ask].map(AgentMode.plan.rejects), [false, true, true, false]);
      expect([view, edit, runTests, ask].every(AgentMode.fullAuto.autoApproves), isTrue);
    });
  });

  group('transcript', () {
    test('the demo session folds into grouped items and a question card', () async {
      final harness = FakeHarness(step: Duration.zero);
      final s = await harness.start(_spec(AgentMode.fullAuto));
      final feed = _Feed(s);
      var t = await feed.until((Transcript x) => x.openQuestion != null && x.status == ExecutionStatus.idle);

      expect(t.items.first, isA<UserTurn>());
      final explore = t.items.whereType<ExploreGroup>().single;
      expect(explore.steps, hasLength(2));
      expect(explore.steps.every((s) => s.done), isTrue);
      expect(exploreSummary(explore.steps), '1 file, 1 search');
      expect(t.plan.first.status, 'in_progress');
      final card = t.openQuestion!;
      expect(card.questions.map((q) => q.multiSelect), [false, true]);

      await s.send(
        answersMessage(card.questions, const [
          QuestionAnswer(selected: {0}),
          QuestionAnswer(selected: {0, 2}),
        ]),
      );
      t = await feed.until((Transcript x) => x.status == ExecutionStatus.finished);

      // The answers attach to the card instead of showing as a user turn.
      expect(t.items.whereType<UserTurn>(), hasLength(1));
      final answered = t.items.whereType<QuestionItem>().single;
      expect(answered.answers![1].selected, {0, 2});
      final edit = t.items.whereType<StepItem>().first.step;
      expect(stepTitle(edit.call), 'Edited lib/counter.dart');
      expect(edit.result!.observation['new_content'], contains('decrement'));
      expect(t.items.whereType<SubagentItem>().single.tasks.keys, ['test-writer']);
      expect(t.plan.every((p) => p.status == 'done'), isTrue);
      expect((t.items.last as AgentText).text, contains('passes'));
      // Consecutive plan updates don't pile up.
      expect(t.items.whereType<PlanItem>(), hasLength(2));
      await feed.cancel();
      await s.close();
    });

    test('ask mode waits for approval and a denial stops the turn', () async {
      final harness = FakeHarness(step: Duration.zero);
      final s = await harness.start(_spec(AgentMode.ask));
      final feed = _Feed(s);
      var t = await feed.until((Transcript x) => x.pending.isNotEmpty);
      expect(stepTitle(t.pending.single), 'Read lib/counter.dart');

      await s.respond(accept: true);
      t = await feed.until((Transcript x) => x.pending.isNotEmpty && x.pending.single.toolName == 'terminal');
      await s.respond(accept: false);
      t = await feed.until((Transcript x) => x.status == ExecutionStatus.idle);
      expect(t.pending, isEmpty);
      await feed.cancel();
      await s.close();
    });

    test('plan updates wait for approval too', () async {
      final harness = FakeHarness(step: Duration.zero, turns: [demoTurns.first.sublist(4)]);
      final s = await harness.start(_spec(AgentMode.ask));
      final feed = _Feed(s);
      final t = await feed.until((Transcript x) => x.pending.isNotEmpty);
      expect(t.pending.single.actionKind, 'TaskTrackerAction');
      expect(AgentMode.ask.autoApproves(t.pending.single), isTrue);
      await feed.cancel();
      await s.close();
    });

    test('a denial is recorded on the step', () async {
      final harness = FakeHarness(step: Duration.zero);
      final s = await harness.start(_spec(AgentMode.ask));
      final feed = _Feed(s);
      var t = await feed.until((Transcript x) => x.pending.isNotEmpty);
      await s.respond(accept: true);
      t = await feed.until((Transcript x) => x.pending.any((c) => c.actionKind == 'TerminalAction'));
      await s.respond(accept: false);
      t = await feed.until((Transcript x) => x.status == ExecutionStatus.idle);
      final grep = t.items.whereType<ExploreGroup>().single.steps.last;
      expect(grep.rejected, isTrue);
      expect(t.pending, isEmpty);
      await feed.cancel();
      await s.close();
    });
  });
}
