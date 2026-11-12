import 'package:every_ai/features/code/drivers/briefing/session_skill.dart';
import 'package:flutter_test/flutter_test.dart';

SessionSkillInput _input({String worktree = '/wt/s1', List<WorkflowInfo> workflows = const []}) => SessionSkillInput(
  worktree: worktree,
  hostTools: const [
    (name: 'ask_user_question', when: 'a decision is the user\'s'),
    (name: 'present_plan', when: 'you finish planning'),
  ],
  workflows: workflows,
);

void main() {
  test('is deterministic and has no dates or times', () {
    final a = sessionBriefing(_input());
    expect(sessionBriefing(_input()), a);
    expect(a, isNot(matches(RegExp(r'\d{4}-\d{2}-\d{2}|\d{2}:\d{2}'))));
  });

  // Owner, 2026-11-11: an outside agent runs on its own modes, approvals and habits; the briefing says only which of
  // EveryAI's tools it has, where it works, and that commits carry no AI identifiers.

  test('commands in session values are defused', () {
    final md = sessionBriefing(_input(worktree: '/wt/!`id`'));
    expect(md, isNot(contains(RegExp(r'(?<!\\)!`id`'))));
    expect(md, contains(r'\!`id`'));
  });
}
