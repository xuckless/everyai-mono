import 'package:every_ai/features/code/settings/agent_prompt.dart';
import 'package:every_ai/features/code/settings/agent_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('layers merge: scalars override when set, lists add up, agents merge by name', () {
    final user = {
      'instructions': 'Keep functions small',
      'git': {'commitStyle': 'plain'},
      'agents': {
        'reviewer': {'description': 'Reviews diffs'},
      },
    };
    final project = {
      'instructions': ['Run dart format -l 120'],
      'agents': {
        'tester': {'description': 'Writes tests', 'prompt': 'Prefer real code paths'},
      },
      'permissions': {
        'deny': ['git push --force'],
      },
    };
    final local = {
      'git': {'commitStyle': 'conventional'},
    };
    final s = AgentSettings.layered([user, project, local]);
    expect(s.instructions, ['Keep functions small', 'Run dart format -l 120']);
    expect(s.commitStyle, CommitStyle.conventional);
    expect(s.attribution, isFalse);
    expect(s.agents.keys, ['reviewer', 'tester']);
    expect(s.deny, ['git push --force']);
    // A layer without git keeps the style below it.
    expect(AgentSettings.layered([user, project]).commitStyle, CommitStyle.plain);
    // Junk is ignored rather than fatal.
    expect(
      AgentSettings.layered([
        {'git': 'nope', 'agents': 3, 'instructions': 7},
      ]).commitStyle,
      CommitStyle.auto,
    );
  });

  test('commit style follows the repository history', () {
    expect(
      detectCommitStyle(['feat(auth): add refresh', 'fix: null check', 'Merge branch x', 'docs: readme', 'Tweak']),
      CommitStyle.conventional,
    );
    expect(
      detectCommitStyle(['Fix layout failures from math in tables', 'Keep question cards open', 'chore: bump']),
      CommitStyle.plain,
    );
    expect(detectCommitStyle(['Initial commit']), CommitStyle.conventional);
    expect(isConventionalSubject('refactor(ui)!: drop old cards'), isTrue);
    expect(isConventionalSubject('Refactor UI'), isFalse);
  });

  test('the persona replaces OpenHands branding with the configured commit rules', () {
    final plain = agentPersona(style: CommitStyle.plain, attribution: false);
    expect(plain, contains('agentic environment'));
    expect(plain, contains('imperative, capitalised subject'));
    expect(plain, contains('No Co-authored-by'));
    expect(plain, isNot(contains('openhands@all-hands.dev')));
    expect(plain, contains('Never set user.name'));
    final conventional = agentPersona(style: CommitStyle.conventional, attribution: true);
    expect(conventional, contains('Conventional Commits'));
    expect(conventional, isNot(contains('No Co-authored-by')));
  });

  test('the suffix carries project rules, agent types and the attribution override', () {
    final s = AgentSettings.layered([
      {
        'instructions': ['Never touch generated files'],
        'agents': {
          'reviewer': {'description': 'Reviews a diff for bugs'},
        },
      },
    ]);
    final suffix = agentPromptSuffix(s);
    expect(suffix, startsWith(workingRules));
    expect(suffix, contains('<ATTRIBUTION>'));
    expect(suffix, contains('- Never touch generated files'));
    expect(suffix, contains('- reviewer: Reviews a diff for bugs'));
    expect(
      agentPromptSuffix(
        AgentSettings.layered([
          {
            'git': {'attribution': true},
          },
        ]),
      ),
      isNot(contains('<ATTRIBUTION>')),
    );
  });
}
