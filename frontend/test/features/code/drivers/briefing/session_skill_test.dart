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

  test('is plain Markdown for an instructions slot, not a skill', () {
    final md = sessionBriefing(_input());
    expect(md, startsWith('# EveryAI session'));
    expect(md, isNot(contains('---')));
  });

  // Owner, 2026-11-11: an outside agent runs on its own modes, approvals and habits; the briefing says only which of
  // EveryAI's tools it has, where it works, and that commits carry no AI identifiers.
  test('says the tools, the working directory and the commit rule, and nothing that steers', () {
    final md = sessionBriefing(_input());
    expect(md, contains('`ask_user_question`: a decision is the user\'s'));
    expect(md, contains('`Co-authored-by` or `Signed-off-by` trailer'));
    expect(md, contains('- Working directory: `/wt/s1`'));
    for (final gone in [
      '<everyai-mode',
      '## Modes',
      '## Rules',
      "## Prefer EveryAI's tools",
      '## Reporting EveryAI problems',
      '## Notices from EveryAI',
      '## Security',
      '## Runtime profiles',
      'Project root',
    ]) {
      expect(md, isNot(contains(gone)), reason: gone);
    }
  });

  test('the working directory comes last: changing it leaves the prefix alone', () {
    final a = sessionBriefing(_input());
    final c = sessionBriefing(_input(worktree: '/wt/other'));
    final cut = a.indexOf('## This session');
    expect(cut, greaterThan(0));
    expect(c.substring(0, cut), a.substring(0, cut));
    expect(c, contains('`/wt/other`'));
  });

  test('workflows are listed one line each, and only when there are some', () {
    final a = sessionBriefing(_input());
    expect(a, isNot(contains('run_workflow')));
    final b = sessionBriefing(
      _input(
        workflows: const [(id: 'ultra', when: 'several independent changes'), (id: 'bugfix', when: 'a bug to fix')],
      ),
    );
    expect(b, contains('`run_workflow`'));
    expect(b.split('\n').where((l) => l.startsWith('- `ultra`') || l.startsWith('- `bugfix`')), [
      '- `ultra`: several independent changes',
      '- `bugfix`: a bug to fix',
    ]);
  });

  test('commands in session values are defused', () {
    final md = sessionBriefing(_input(worktree: '/wt/!`id`'));
    expect(md, isNot(contains(RegExp(r'(?<!\\)!`id`'))));
    expect(md, contains(r'\!`id`'));
  });
}
