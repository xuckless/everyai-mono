import 'dart:convert';

import 'package:every_ai/app/shell.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/ui/code_settings_screen.dart';
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' as m;
import 'package:every_ai/features/code/code_settings_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/mcp_providers.dart';
import 'package:every_ai/features/code/permissions_providers.dart';
import 'package:every_ai/features/skills/skills_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

    test('a layer survives the editor unchanged', () {
      for (final scope in [SettingsScope.global, SettingsScope.project]) {
        final text = prettyJson(layerJson(scope, sources, projectId: 'p1'));
        final parsed = parseLayer(scope, text);
        expect(parsed.errors, isEmpty, reason: scope.name);
      }
      final session = parseLayer(SettingsScope.session, prettyJson(layerJson(SettingsScope.session, sources)));
      expect(session.edit!.mode, AgentMode.plan);
      expect(session.edit!.budgetUsd, 2.0);
    });
  });

  group('parseLayer', () {
    test('reports bad JSON, unknown keys and wrong types, and saves nothing', () {
      expect(parseLayer(SettingsScope.global, '{').errors.single, startsWith('Not valid JSON'));
      expect(parseLayer(SettingsScope.global, '[]').errors.single, contains('JSON object'));
      final bad = parseLayer(
        SettingsScope.project,
        jsonEncode({
          'skills': <String, Object?>{},
          'permissions': {'allow': 'x', 'ask': <String>[]},
          'mcpServers': [
            {'name': 'a', 'command': 'x'},
            {'name': 'a', 'command': 'y'},
            {'command': 'z'},
            {'name': 'r', 'transport': 'http', 'url': 'ftp://x'},
          ],
        }),
      );
      expect(bad.edit, isNull);
      expect(bad.errors, [
        'Unknown key "skills" in project settings.',
        'Unknown key "ask" in permissions.',
        'permissions.allow must be a list of strings.',
        'Two MCP servers are called "a".',
        'mcpServers[2] needs at least a "name".',
        'MCP server "r": A remote server needs an http(s) URL.',
      ]);
    });

    test('a key left out clears the layer; an approved key is ignored', () {
      final e = parseLayer(
        SettingsScope.global,
        jsonEncode({
          'mcpServers': [
            {'name': 'fs', 'command': 'npx', 'approved': 'forged'},
          ],
        }),
      ).edit!;
      expect(e.systemPrompt, '');
      expect(e.permissions!.isEmpty, isTrue);
      expect(e.skillsDisabled, isEmpty);
      expect(e.mcpServers!.single.approved, isNull);
    });

    test('session: keys left out stay; null budget clears it; bad mode fails', () {
      final e = parseLayer(SettingsScope.session, '{"budgetUsd": null}').edit!;
      expect(e.model, isNull);
      expect(e.mode, isNull);
      expect(e.clearBudget, isTrue);
      expect(parseLayer(SettingsScope.session, '{"mode": "yolo"}').errors.single, startsWith('mode must be one of'));
      expect(parseLayer(SettingsScope.session, '{"systemPrompt": "x"}').errors.single, contains('Unknown key'));
    });
  });

  test('keepApprovals carries approval only for an unchanged command', () {
    final approved = _fs.approve();
    final kept = keepApprovals([approved], [_fs, const McpServer(name: 'other', command: 'x')]);
    expect(kept.first.needsConsent, isFalse);
    expect(kept.last.approved, isNull);
    final changed = keepApprovals(
      [approved],
      [
        const McpServer(name: 'fs', command: 'rm', args: ['-rf', '/']),
      ],
    );
    expect(changed.single.needsConsent, isTrue);
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

  test('applyLayer writes into the existing stores and keeps approvals and trust', () {
    final prefs = Preferences.inMemory({
      CodeMcpServers.key: jsonEncode(StoredMcpServers(global: [_fs.approve()]).toJson()),
      SkillSettingsNotifier.key: jsonEncode(const SkillSettings(trusted: {'k': 'd'}).toJson()),
    });
    final c = ProviderContainer(overrides: [preferencesProvider.overrideWithValue(prefs)]);
    addTearDown(c.dispose);
    c.read(codePermissionsProvider);
    final edit = parseLayer(
      SettingsScope.global,
      jsonEncode({
        'systemPrompt': 'Be brief.',
        'permissions': {
          'deny': ['rm -rf *'],
        },
        'mcpServers': [_fs.toJson()..remove('approved')],
        'skills': {
          'disabled': ['library:slides'],
        },
      }),
    ).edit!;
    c.read(codeSettingsProvider.notifier).applyLayer(SettingsScope.global, edit);
    expect(c.read(codeSettingsProvider).globalPrompt, 'Be brief.');
    expect(c.read(codePermissionsProvider).global.deny, ['rm -rf *']);
    expect(c.read(codeMcpServersProvider).global.single.active, isTrue);
    expect(c.read(skillSettingsProvider).disabled, {'library:slides'});
    expect(c.read(skillSettingsProvider).trusted, {'k': 'd'});
    // Stored in each store's own key and format.
    expect(jsonDecode(prefs[CodePermissions.key]!), {
      'global': {
        'allow': <String>[],
        'deny': ['rm -rf *'],
      },
      'projects': <String, Object?>{},
    });

    final project = parseLayer(SettingsScope.project, '{"systemPrompt": "Use pnpm."}').edit!;
    c.read(codeSettingsProvider.notifier).applyLayer(SettingsScope.project, project, projectId: 'p1');
    expect(c.read(codeSettingsProvider).promptFor('p1'), 'Use pnpm.');
    expect(c.read(codeMcpServersProvider).global, hasLength(1), reason: 'the project layer leaves global alone');
    expect(() => c.read(codeSettingsProvider.notifier).applyLayer(SettingsScope.project, project), throwsStateError);
  });

  testWidgets('the settings screen saves a layer and shows what is wrong', (tester) async {
    tester.view.physicalSize = const Size(1000, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final prefs = Preferences.inMemory();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [preferencesProvider.overrideWithValue(prefs)],
        child: m.MaterialApp(
          home: EveryThemeScope(
            theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
            child: ShellScope(
              sidebarVisible: true,
              compact: false,
              toggleSidebar: () {},
              child: const CodeSettingsScreen(),
            ),
          ),
        ),
      ),
    );
    final container = ProviderScope.containerOf(tester.element(find.byType(CodeSettingsScreen)));
    final editor = find.byKey(const ValueKey('code-settings.editor.global.json'));
    expect(editor, findsOneWidget);
    expect(find.textContaining('"systemPrompt": ""'), findsOneWidget);

    await tester.enterText(find.descendant(of: editor, matching: find.byType(EditableText)), '{"colour": 1}');
    await tester.tap(find.byKey(const ValueKey('code-settings.save')));
    await tester.pump();
    expect(find.text('Unknown key "colour" in global settings.'), findsOneWidget);

    await tester.enterText(
      find.descendant(of: editor, matching: find.byType(EditableText)),
      '{"permissions": {"deny": ["git push *"]}}',
    );
    await tester.tap(find.byKey(const ValueKey('code-settings.save')));
    await tester.pump();
    expect(container.read(codePermissionsProvider).global.deny, ['git push *']);

    await tester.tap(find.byKey(const ValueKey('code-settings.tab.prompt')));
    await tester.pump();
    final prompt = find.byKey(const ValueKey('code-settings.editor.global.prompt'));
    await tester.enterText(find.descendant(of: prompt, matching: find.byType(EditableText)), 'Be brief.');
    await tester.tap(find.byKey(const ValueKey('code-settings.save')));
    await tester.pump();
    expect(container.read(codeSettingsProvider).globalPrompt, 'Be brief.');

    await tester.tap(find.byKey(const ValueKey('code-settings.tab.effective')));
    await tester.pump();
    expect(find.textContaining('"systemPrompt": "Be brief."'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });
}
