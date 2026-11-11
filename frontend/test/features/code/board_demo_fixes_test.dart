import 'package:every_ai/features/code/board/board_plan.dart';
import 'package:every_ai/features/code/board/board_pr.dart';
import 'package:every_ai/features/code/board/board_providers.dart';
import 'package:every_ai/features/code/board/board_triage.dart';
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

Transcript _t(List<Map<String, Object?>> events) {
  final b = TranscriptBuilder();
  for (final e in events) {
    b.add(HarnessEvent.decode(e));
  }
  return b.snapshot;
}

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
Map<String, Object?> _agent(String id, String text) => _msg(id, 'agent', text);
Map<String, Object?> _error(String id, String detail) => {'kind': 'ConversationErrorEvent', 'id': id, 'detail': detail};

void main() {
  group('plainActivityLine', () {
    test('takes the Markdown out of one line', () {
      expect(plainActivityLine('I added the **Import tab**:'), 'I added the Import tab:');
      expect(plainActivityLine('Ran `flutter test` and _all_ passed'), 'Ran flutter test and all passed');
      expect(plainActivityLine('## Summary'), 'Summary');
      expect(plainActivityLine('- [x] done the [docs](https://x.dev/a)'), 'done the docs');
      expect(plainActivityLine('1. **_both_** kinds'), 'both kinds');
      expect(plainActivityLine('> quoted ~~old~~ text'), 'quoted old text');
    });

    test('keeps plain words with stars and underscores in them', () {
      expect(plainActivityLine('a * b and snake_case_name'), 'a * b and snake_case_name');
      expect(plainActivityLine('2 * 3 = 6'), '2 * 3 = 6');
    });

    test('the first non-blank line only', () {
      expect(plainActivityLine('\n\n  **Done.**\nMore below'), 'Done.');
      expect(plainActivityLine('   '), '');
    });

    test("the card's activity reads plain text", () {
      final t = _t([_user('u1', 'go'), _agent('a1', 'Next, the **Import tab**:\n- step one')]);
      expect(boardActivity(t), 'Next, the Import tab:');
    });
  });

  group('endedOnFailure', () {
    test('a run whose last item is an error notice failed', () {
      final t = _t([_user('u1', 'go'), _agent('a1', 'Working'), _error('e1', 'Codex stopped: ERROR boom')]);
      expect(endedOnFailure(t), isTrue);
    });

    test('a reply after the error means it went on', () {
      final t = _t([_user('u1', 'go'), _error('e1', 'Codex stopped: ERROR'), _user('u2', 'again'), _agent('a2', 'ok')]);
      expect(endedOnFailure(t), isFalse);
    });

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

    test('a clean finish and an empty transcript did not fail', () {
      expect(endedOnFailure(_t([_user('u1', 'go'), _agent('a1', 'Done')])), isFalse);
      expect(endedOnFailure(_t([])), isFalse);
    });
  });

  group('finishedPrOwner', () {
    test('the newest session on a branch owns its finished pull request', () {
      final all = [_s('a', day: 1), _s('b', day: 3), _s('c', day: 2)];
      for (final s in all) {
        expect(finishedPrOwner(all, s), 'b');
      }
    });

    test('other branches, other projects and the default branch stay apart', () {
      final a = _s('a', day: 1);
      final other = _s('o', day: 5, branch: 'feat/y');
      final elsewhere = _s('e', day: 6, project: 'p2');
      final all = [a, other, elsewhere];
      expect(finishedPrOwner(all, a), 'a');
      expect(finishedPrOwner(all, other), 'o');
      expect(finishedPrOwner(all, _s('m', branch: 'main')), isNull);
    });

    test('a session EveryAI opened the PR for keeps it; the branch sessions share theirs', () {
      final opened = _s('p', day: 1, pr: 2);
      final later = _s('l', day: 4);
      final all = [opened, later];
      expect(finishedPrOwner(all, opened), 'p');
      expect(finishedPrOwner(all, later), 'l');
    });
  });

  group('inspector body', () {
    test('a live session loads until it connects or shows something; a failure ends the loading', () {
      expect(liveInspectorBody(connected: false, failed: false, hasItems: false), InspectorBody.loading);
      expect(liveInspectorBody(connected: true, failed: false, hasItems: false), InspectorBody.transcript);
      expect(liveInspectorBody(connected: false, failed: true, hasItems: false), InspectorBody.transcript);
      expect(liveInspectorBody(connected: false, failed: false, hasItems: true), InspectorBody.transcript);
    });

    test('a preview loads until its read answers, then shows it or says nothing recent', () {
      expect(previewInspectorBody(loading: true, found: false), InspectorBody.loading);
      expect(previewInspectorBody(loading: false, found: true), InspectorBody.transcript);
      expect(previewInspectorBody(loading: false, found: false), InspectorBody.empty);
    });
  });

  test('segmentsFit: each option takes the widest label', () {
    expect(segmentsFit(count: 3, widestLabel: 60, maxWidth: 260), isTrue); // 3 × 84 + 8
    expect(segmentsFit(count: 3, widestLabel: 60, maxWidth: 259), isFalse);
  });

  test('planCount: a blank draft is not counted; written drafts, planned goals and races are', () {
    PlanGoal goal(String id, {String text = '', GoalStage stage = GoalStage.draft}) => PlanGoal(
      id: id,
      projectId: 'p1',
      planner: (harness: 'everyai', model: ''),
      createdAt: DateTime(2026, 11, 1),
      text: text,
      stage: stage,
    );
    expect(planCount([goal('a')], 0), 0);
    expect(planCount([goal('a', text: '   ')], 0), 0);
    expect(planCount([goal('a', text: 'Add login')], 0), 1);
    expect(planCount([goal('a'), goal('b', stage: GoalStage.running, text: 'x')], 2), 3);
  });
}
