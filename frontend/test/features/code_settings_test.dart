import 'dart:convert';

import 'package:every_ai/features/code/code_settings_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/mcp_providers.dart';
import 'package:every_ai/features/code/permissions_providers.dart';
import 'package:every_ai/features/skills/skills_providers.dart';
import 'package:flutter_test/flutter_test.dart';

const _fs = McpServer(name: 'fs', command: 'npx', args: ['-y', 'server-fs']);

void main() {
  group('StoredCodeSettings', () {
    test('round-trips prompts and budgets, dropping empty ones', () {
      final s = const StoredCodeSettings()
          .withPrompt(null, '  Use British English. ')
          .withPrompt('p1', 'Use pnpm.')
          .withPrompt('p2', '')
          .withBudget('s1', 5)
          .withBudget('s2', 0);
      final back = StoredCodeSettings.fromJson(jsonDecode(jsonEncode(s.toJson())));
      expect(back.globalPrompt, 'Use British English.');
      expect(back.promptFor('p1'), 'Use pnpm.');
      expect(back.projectPrompts.containsKey('p2'), isFalse);
      expect(back.budgets, {'s1': 5.0});
      expect(back.withBudget('s1', null).budgets, isEmpty);
    });

    test('reads junk as empty', () {
      expect(StoredCodeSettings.fromJson('nope').globalPrompt, '');
      expect(
        StoredCodeSettings.fromJson({
          'sessions': {
            's': {'budgetUsd': 'x'},
          },
        }).budgets,
        isEmpty,
      );
    });
  });

  group('layers', () {
    final sources = CodeSettingsSources(
      settings: const StoredCodeSettings(globalPrompt: 'G', projectPrompts: {'p1': 'P'}),
      permissions: const StoredPermissions(
        global: PermissionRules(deny: ['git push *']),
        projects: {
          'p1': PermissionRules(allow: ['npm test *']),
        },
      ),
      mcp: StoredMcpServers(
        global: [_fs.approve()],
        projects: const {
          'p1': [McpServer(name: 'docs', transport: McpTransport.http, url: 'https://example.com/mcp')],
        },
      ),
      skills: const SkillSettings(disabled: {'library:slides'}, trusted: {'project:p1:x': 'abc'}),
      session: (model: 'anthropic/claude-haiku-5.5', effort: 'low', mode: AgentMode.plan, budgetUsd: 2.0),
    );

    test('each layer shows its own values, without approvals or trust', () {
      final global = layerJson(SettingsScope.global, sources);
      expect(global['systemPrompt'], 'G');
      expect(global['permissions'], {
        'allow': <String>[],
        'deny': ['git push *'],
      });
      expect((global['mcpServers']! as List).single, isNot(contains('approved')));
      expect(global['skills'], {
        'disabled': ['library:slides'],
      });
      final project = layerJson(SettingsScope.project, sources, projectId: 'p1');
      expect(project.keys, ['systemPrompt', 'permissions', 'mcpServers']);
      expect(project['systemPrompt'], 'P');
      final session = layerJson(SettingsScope.session, sources);
      expect(session, {'model': 'anthropic/claude-haiku-5.5', 'effort': 'low', 'mode': 'plan', 'budgetUsd': 2.0});
    });

    test('the effective view merges every layer', () {
      final e = effectiveJson(sources, projectId: 'p1');
      expect(e['systemPrompt'], 'G\n\nP');
      expect(e['permissions'], {
        'allow': ['npm test *'],
        'deny': ['git push *'],
      });
      expect([for (final s in e['mcpServers']! as List) (s as Map)['name']], ['fs', 'docs']);
      expect(((e['mcpServers']! as List).first as Map)['active'], isTrue);
      expect(e['mode'], 'plan');
    });
  });

  test('withSystemPrompts appends a block only when there are prompts', () {
    expect(withSystemPrompts('BASE', global: ' ', project: ''), 'BASE');
    final s = withSystemPrompts('BASE', global: 'Be brief.', project: 'Use pnpm.');
    expect(s, startsWith('BASE\n\n<USER_SYSTEM_PROMPT>\n'));
    expect(s, contains('\nBe brief.\n'));
    expect(s, contains('For this project:\nUse pnpm.\n'));
    expect(s, endsWith('</USER_SYSTEM_PROMPT>'));
    expect(withSystemPrompts('B', global: '', project: 'P'), isNot(contains('\n\n\nFor')));
  });

  test('crossedBudget fires once, at the crossing', () {
    expect(crossedBudget(0, 900000, 1), isFalse);
    expect(crossedBudget(900000, 1000000, 1), isTrue);
    expect(crossedBudget(1000000, 1200000, 1), isFalse);
    expect(crossedBudget(0, 5000000, null), isFalse);
    expect(budgetFill(500000, 2), 0.25);
    expect(budgetFill(5, null), isNull);
  });
}
