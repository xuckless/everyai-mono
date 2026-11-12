import 'dart:async';
import 'dart:convert';

import 'package:every_ai/features/code/domain/agent_mode.dart';
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
  group('events', () {});

  group('questions', () {});

  group('modes', () {
    final view = _call({'kind': 'FileEditorAction', 'command': 'view', 'path': 'a'}, tool: 'file_editor');
    final edit = _call({'kind': 'FileEditorAction', 'command': 'str_replace', 'path': 'a'}, tool: 'file_editor');
    final ls = _call({'kind': 'TerminalAction', 'command': 'ls -la'});
    final sneaky = _call({'kind': 'TerminalAction', 'command': 'ls; rm -rf build'});
    final runTests = _call({'kind': 'TerminalAction', 'command': 'flutter test'});
    final ask = _call({}, tool: askUserQuestionTool);

    test('read-only detection follows every part of a chained command', () {
      expect(AgentMode.isReadOnly(ls), isTrue);
      expect(AgentMode.isReadOnly(sneaky), isFalse);
      expect(
        AgentMode.isReadOnly(_call({'kind': 'TerminalAction', 'command': 'cat a.dart; git log -3 | head'})),
        isTrue,
      );
      expect(AgentMode.isReadOnly(_call({'kind': 'TerminalAction', 'command': 'ls', 'is_input': true})), isFalse);
      expect(AgentMode.isReadOnly(view), isTrue);
      expect(AgentMode.isReadOnly(edit), isFalse);
    });

    test('each mode approves what it should', () {
      expect([view, edit, runTests, ask].map(AgentMode.ask.autoApproves), [true, false, false, true]);
      expect([view, edit, runTests, ask].map(AgentMode.autoEdit.autoApproves), [true, true, false, true]);
      expect([view, edit, runTests, ask].map(AgentMode.plan.rejects), [false, true, true, false]);
      expect([view, edit, runTests, ask].every(AgentMode.fullAuto.autoApproves), isTrue);
      final plan = _call({}, tool: presentPlanTool);
      expect(AgentMode.plan.autoApproves(plan) && !AgentMode.plan.rejects(plan), isTrue);
    });
  });

  group('mode notes and plans in the transcript', () {});

  group('transcript', () {
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
  });

  group('question cards', () {
    HarnessEvent msg(String id, String source, String text) => HarnessEvent.decode({
      'kind': 'MessageEvent',
      'id': id,
      'source': source,
      'llm_message': {
        'role': source == 'user' ? 'user' : 'assistant',
        'content': [
          {'type': 'text', 'text': text},
        ],
      },
    });
    HarnessEvent state(String id, String status) => HarnessEvent.decode({
      'kind': 'ConversationStateUpdateEvent',
      'id': id,
      'key': 'execution_status',
      'value': status,
    });
    final questions = [
      for (final h in ['Platform', 'Review', 'Validation', 'Address'])
        {
          'question': 'Which $h?',
          'header': h,
          'options': [
            {'label': '$h A', 'description': 'first'},
            {'label': '$h B', 'description': 'second'},
          ],
        },
    ];
    HarnessEvent ask() => HarnessEvent.decode({
      'kind': 'ActionEvent',
      'id': 'q1',
      'tool_name': askUserQuestionTool,
      'tool_call_id': 'tc1',
      'action': {'kind': 'ClientToolAction'},
      'tool_call': {
        'name': askUserQuestionTool,
        'arguments': jsonEncode({'questions': questions}),
      },
    });
    HarnessEvent ack() => HarnessEvent.decode({
      'kind': 'ObservationEvent',
      'id': 'o1',
      'action_id': 'q1',
      'tool_call_id': 'tc1',
      'tool_name': askUserQuestionTool,
      'observation': {
        'kind': 'ClientToolObservation',
        'content': [
          {'type': 'text', 'text': 'Tool call dispatched to client.'},
        ],
      },
    });

    // The shape of the user's sessions: the card, the SDK's ack, the agent's
    // "I've asked four questions above", then finished.
    TranscriptBuilder asked() => TranscriptBuilder()
      ..add(msg('u1', 'user', 'Plan a signup form and ask me questions'))
      ..add(state('s1', 'running'))
      ..add(ask())
      ..add(ack())
      ..add(msg('m1', 'agent', "I've asked four questions above. I'll wait for your answers."))
      ..add(state('s2', 'finished'));

    test('a card stays open after the agent keeps talking and the turn ends', () {
      final t = asked().snapshot;
      expect(t.items.last, isA<AgentText>());
      expect(t.openQuestion?.questions, hasLength(4));
      expect(t.openQuestion!.questions.map((q) => q.header), ['Platform', 'Review', 'Validation', 'Address']);
    });

    group('held in the call', () {
      HarnessEvent reject(String actionId, String reason) => HarnessEvent.decode({
        'kind': 'UserRejectObservation',
        'id': 'r-$actionId',
        'action_id': actionId,
        'tool_name': askUserQuestionTool,
        'rejection_reason': reason,
      });
      TranscriptBuilder held() => TranscriptBuilder()
        ..add(msg('u1', 'user', 'Plan a signup form and ask me questions'))
        ..add(state('s1', 'running'))
        ..add(ask())
        ..add(state('s2', 'waiting_for_confirmation'));

      test('a held card is not an approval: it waits as held, not pending', () {
        final t = held().snapshot;
        expect(t.pending, isEmpty);
        expect(t.held.single.toolName, askUserQuestionTool);
        expect(t.openQuestion, isNotNull);
      });

      test('a held plan is approved or revised by the reason', () {
        HarnessEvent plan(String id) => HarnessEvent.decode({
          'kind': 'ActionEvent',
          'id': id,
          'tool_name': presentPlanTool,
          'action': {
            'title': 'Form',
            'steps': ['Build it'],
          },
        });
        final b = TranscriptBuilder()
          ..add(plan('p1'))
          ..add(state('s1', 'waiting_for_confirmation'));
        expect(b.snapshot.held.single.id, 'p1');
        expect(b.snapshot.pending, isEmpty);
        b
          ..add(reject('p1', '$planRevisionLead use a stepper'))
          ..add(plan('p2'))
          ..add(reject('p2', planApprovedReason));
        expect(b.snapshot.items.whereType<PlanProposal>().map((p) => p.verdict), [
          PlanVerdict.revised,
          PlanVerdict.approved,
        ]);
      });
    });
  });

  group('an outside agent\'s host calls', () {});
}
