import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/features/code/board/board_plan.dart';
import 'package:every_ai/features/code/board/board_plan_providers.dart' show SessionOutcome, sessionOutcome;
import 'package:every_ai/features/code/board/board_race.dart';
import 'package:every_ai/features/code/board/board_screen.dart' show boardBreathing;
import 'package:every_ai/features/code/board/board_triage.dart';
import 'package:every_ai/features/code/code_providers.dart'
    show CodeFailedRuns, CodeSessionState, codeFailedRunsProvider, failedRunStatus;
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/subagents.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/drivers/acp/acp_mapping.dart';
import 'package:every_ai/features/code/drivers/driver_events.dart' show stateEvent;
import 'package:every_ai/features/code/harness/events.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// Review fixes on the Board v2 demo fixes (2026-11-11): informational notices vs failures, ACP stop reasons, the
// failed marker for closed sessions, Retry after a failure, fork reports, the ambient clock, the inspector's wait.

Map<String, Object?> _msg(String id, String source, String text) => {
  'kind': 'MessageEvent',
  'id': id,
  'source': source,
  'llm_message': {
    'role': source == 'user' ? 'user' : 'assistant',
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
};

TranscriptBuilder _run(List<HarnessEvent> events) {
  final b = TranscriptBuilder();
  events.forEach(b.add);
  return b;
}

HarnessEvent _user(String id, String text) => HarnessEvent.decode(_msg(id, 'user', text));
HarnessEvent _agent(String id, String text) => HarnessEvent.decode(_msg(id, 'agent', text));
HarnessEvent _error(String id, String detail) =>
    HarnessEvent.decode({'kind': 'ConversationErrorEvent', 'id': id, 'detail': detail});

SessionStatus _status(TranscriptBuilder b) => CodeSessionState(connected: true, transcript: b.snapshot).status;

void main() {
  group('fatal vs informational notices', () {
    test('an ACP note (a refused mode switch on an idle session) is not a failure', () {
      final b = _run([
        _user('u1', 'go'),
        stateEvent('s1', ExecutionStatus.running),
        _agent('a1', 'Done.'),
        stateEvent('s2', ExecutionStatus.finished),
        acpNotice('n1', "Gemini didn't switch to its plan mode: unsupported"),
      ]);
      final notice = b.snapshot.items.last as NoticeItem;
      expect(notice.error, isTrue);
      expect(notice.fatal, isFalse);
      expect(endedOnFailure(b.snapshot), isFalse);
      expect(_status(b), SessionStatus.done);
    });

    test('a fatal ACP notice (the prompt failed) is', () {
      final b = _run([_user('u1', 'go'), acpNotice('n1', 'Gemini stopped', fatal: true)]);
      expect(endedOnFailure(b.snapshot), isTrue);
    });

    test('Claude notes (nothing to remember; a refused control request) are not failures', () {
      for (final raw in <Map<String, Object?>>[
        {'kind': 'ConversationErrorEvent', 'id': 'e1', 'source': 'environment', 'fatal': false, 'detail': 'once'},
        {'kind': 'ConversationErrorEvent', 'id': 'e2', 'fatal': false, 'detail': 'set_model refused'},
      ]) {
        final b = _run([_user('u1', 'go'), _agent('a1', 'ok'), HarnessEvent.decode(raw)]);
        expect(endedOnFailure(b.snapshot), isFalse, reason: '$raw');
      }
    });

    test('events recorded before the flag: plain errors stay fatal, environment notes are informational', () {
      final plain = HarnessEvent.decode({'kind': 'ConversationErrorEvent', 'detail': 'boom'}) as ConversationFailure;
      final note = HarnessEvent.decode({
        'kind': 'ConversationErrorEvent',
        'source': 'environment',
        'detail': 'x',
      }) as ConversationFailure;
      expect(plain.fatal, isTrue);
      expect(note.fatal, isFalse);
    });

    test('a note after a real failure does not undo it', () {
      final b = _run([_user('u1', 'go'), _error('e1', 'Codex stopped'), acpNotice('n1', 'a note')]);
      expect(endedOnFailure(b.snapshot), isTrue);
    });
  });

  group('ACP stop reasons', () {
    test('max_tokens and max_turn_requests finish; refusal and error fail; cancelled pauses', () {
      expect(acpStopOutcome('end_turn'), (status: ExecutionStatus.finished, fatal: false));
      expect(acpStopOutcome('max_tokens'), (status: ExecutionStatus.finished, fatal: false));
      expect(acpStopOutcome('max_turn_requests'), (status: ExecutionStatus.finished, fatal: false));
      expect(acpStopOutcome('refusal'), (status: ExecutionStatus.finished, fatal: true));
      expect(acpStopOutcome('error'), (status: ExecutionStatus.error, fatal: true));
      expect(acpStopOutcome('cancelled'), (status: ExecutionStatus.paused, fatal: false));
      expect(acpStopOutcome(null), (status: ExecutionStatus.finished, fatal: false));
    });

    for (final (stop, expected) in [
      ('max_tokens', SessionStatus.done),
      ('max_turn_requests', SessionStatus.done),
      ('refusal', SessionStatus.failed),
    ]) {
      test('a turn that stopped on $stop reads ${expected.name}', () {
        final o = acpStopOutcome(stop);
        final b = _run([
          _user('u1', 'go'),
          stateEvent('s1', ExecutionStatus.running),
          _agent('a1', 'partial'),
          acpNotice('n1', 'stopped: $stop', fatal: o.fatal),
          stateEvent('s2', o.status),
        ]);
        expect(_status(b), expected);
      });
    }
  });

  test("a failed background fork's report is not the lead's failure", () {
    final report = taskNotification('child-1', 'Fix the tests', const SubagentReport(SubagentStatus.failed, 'boom'));
    final b = _run([
      _user('u1', 'go'),
      stateEvent('s1', ExecutionStatus.running),
      _agent('a1', 'Started a fork.'),
      stateEvent('s2', ExecutionStatus.finished),
      _user('u2', report),
    ]);
    final notice = b.snapshot.items.last as NoticeItem;
    expect(notice.error, isTrue, reason: 'still shown as an error');
    expect(notice.fatal, isFalse);
    expect(endedOnFailure(b.snapshot), isFalse);
    expect(_status(b), SessionStatus.done);
  });

  group('closed sessions keep a failure', () {
    test('failedRunStatus: idle or done after a failed run reads Failed; running and waiting are past it', () {
      expect(failedRunStatus(SessionStatus.idle, failedRun: true), SessionStatus.failed);
      expect(failedRunStatus(SessionStatus.done, failedRun: true), SessionStatus.failed);
      expect(failedRunStatus(SessionStatus.running, failedRun: true), SessionStatus.running);
      expect(failedRunStatus(SessionStatus.needsInput, failedRun: true), SessionStatus.needsInput);
      expect(failedRunStatus(SessionStatus.idle, failedRun: false), SessionStatus.idle);
    });

    test('the marker is kept in Preferences, cleared, and forgotten with the session', () {
      final prefs = Preferences.inMemory();
      ProviderContainer container() => ProviderContainer(overrides: [preferencesProvider.overrideWithValue(prefs)]);
      final c = container();
      addTearDown(c.dispose);
      c.read(codeFailedRunsProvider.notifier).set('s1', failed: true);
      c.read(codeFailedRunsProvider.notifier).set('s2', failed: true);
      // The next app run reads it back: a closed Codex session stays Failed.
      final again = container();
      addTearDown(again.dispose);
      expect(again.read(codeFailedRunsProvider), {'s1', 's2'});
      again.read(codeFailedRunsProvider.notifier).set('s1', failed: false);
      again.read(codeFailedRunsProvider.notifier).forget(['s2']);
      expect(again.read(codeFailedRunsProvider), isEmpty);
      expect(prefs[CodeFailedRuns.key], isNull);
    });

    test('a plan task on a closed failed session fails (its outcome reads the polled Failed)', () {
      final info = CodeSessionInfo(
        id: 's1',
        projectId: 'p',
        title: 't',
        conversationId: 'c',
        model: 'a/m',
        mode: AgentMode.ask,
        workingDir: '/tmp/p',
        createdAt: DateTime(2026, 11, 1),
      );
      final own = failedRunStatus(SessionStatus.idle, failedRun: true);
      expect(sessionOutcome(info: info, own: own, childrenWorking: false), SessionOutcome.failed);
    });
  });

  test('Retry is offered after a failure the harness reports as idle, and its carry-on turn clears it', () {
    final b = _run([
      _user('u1', 'go'),
      stateEvent('s1', ExecutionStatus.running),
      _error('e1', 'Codex stopped: ERROR'),
      stateEvent('s2', ExecutionStatus.idle),
    ]);
    // The view's Retry row shows for it (status error/stuck, or endedOnFailure).
    expect(b.snapshot.status, ExecutionStatus.idle);
    expect(endedOnFailure(b.snapshot), isTrue);
    b
      ..add(_user('u2', 'Carry on from where you stopped.'))
      ..add(stateEvent('s3', ExecutionStatus.running));
    expect(endedOnFailure(b.snapshot), isFalse);
    expect(_status(b), SessionStatus.running);
  });

  test('ambient clock: a running goal breathes only while the lane shows; a settled one does not', () {
    PlanGoal goal(GoalStage stage) => PlanGoal(
      id: 'g',
      projectId: 'p',
      planner: (harness: 'everyai', model: ''),
      createdAt: DateTime(2026, 11, 1),
      text: 'x',
      stage: stage,
    );
    final running = [goal(GoalStage.running)];
    expect(boardBreathing(cards: false, laneShown: true, goals: running, races: const []), isTrue);
    expect(boardBreathing(cards: false, laneShown: false, goals: running, races: const []), isFalse);
    expect(boardBreathing(cards: false, laneShown: true, goals: [goal(GoalStage.failed)], races: const []), isFalse);
    expect(boardBreathing(cards: true, laneShown: false, goals: const [], races: const <BoardRace>[]), isTrue);
  });

  test('the inspector waits, then says it is still connecting', () {
    expect(connectWaitAfter(Duration.zero), ConnectWait.waiting);
    expect(connectWaitAfter(const Duration(seconds: 14)), ConnectWait.waiting);
    expect(connectWaitAfter(inspectorConnectPatience), ConnectWait.slow);
  });
}
