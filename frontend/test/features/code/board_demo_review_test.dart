import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/features/code/code_providers.dart'
    show CodeFailedRuns, CodeSessionState, codeFailedRunsProvider;
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
SessionStatus _status(TranscriptBuilder b) => CodeSessionState(connected: true, transcript: b.snapshot).status;

void main() {
  group('fatal vs informational notices', () {
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
  });
}
