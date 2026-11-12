import 'package:every_ai/features/code/board/board_pr.dart';
import 'package:every_ai/features/code/code_providers.dart' show CodeSessionState;
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/drivers/driver_events.dart' show stateEvent;
import 'package:every_ai/features/code/harness/events.dart';
import 'package:flutter_test/flutter_test.dart';

// Fixes from the owner's live demo of Board v2 (2026-11-11).

CodeSessionInfo _s(String id, {String branch = 'feat/x', int day = 1, String project = 'p1', int? pr}) =>
    CodeSessionInfo(
      id: id,
      projectId: project,
      title: 'Session $id',
      conversationId: 'c-$id',
      model: 'a/m',
      mode: AgentMode.ask,
      workingDir: '/tmp/$project',
      createdAt: DateTime(2026, 11, day),
      branch: branch,
      prNumber: pr,
    );

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

Map<String, Object?> _user(String id, String text) => _msg(id, 'user', text);
Map<String, Object?> _error(String id, String detail) => {'kind': 'ConversationErrorEvent', 'id': id, 'detail': detail};

void main() {
  group('endedOnFailure', () {
    test('Codex reattached idle after "Codex stopped": the session reads failed, not done', () {
      final b = TranscriptBuilder()
        ..add(HarnessEvent.decode(_user('u1', 'go')))
        ..add(stateEvent('s1', ExecutionStatus.running))
        ..add(HarnessEvent.decode(_error('e1', 'Codex stopped: ERROR stream closed')))
        ..add(stateEvent('s2', ExecutionStatus.error))
        ..add(stateEvent('s3', ExecutionStatus.idle));
      expect(CodeSessionState(connected: true, transcript: b.snapshot).status, SessionStatus.failed);
      // The next message runs again: no longer failed.
      b
        ..add(HarnessEvent.decode(_user('u2', 'again')))
        ..add(stateEvent('s4', ExecutionStatus.running));
      expect(CodeSessionState(connected: true, transcript: b.snapshot).status, SessionStatus.running);
    });
  });

  group('finishedPrOwner', () {
    // Every card here found PR #2 unless [numbers] says otherwise.
    String owner(List<CodeSessionInfo> shown, CodeSessionInfo s, {Map<String, int?> numbers = const {}}) =>
        finishedPrOwner(shown, s, number: 2, numberOf: (id) => numbers.containsKey(id) ? numbers[id] : 2);

    test('a session EveryAI opened the PR for wins over newer branch sessions, which group with it', () {
      final opened = _s('p', day: 1, pr: 2);
      final later = _s('l', day: 4);
      final all = [opened, later];
      expect(owner(all, opened), 'p');
      expect(owner(all, later), 'p');
    });
  });
}
