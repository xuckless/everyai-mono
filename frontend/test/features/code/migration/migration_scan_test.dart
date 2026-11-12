import 'dart:io';

import 'package:every_ai/features/agents/domain/agent_definition.dart';
import 'package:every_ai/features/code/domain/mcp_servers.dart';
import 'package:every_ai/features/code/migration/migration_scan.dart';
import 'package:flutter_test/flutter_test.dart';

String fx(String name) => File('test/fixtures/migration/$name').readAsStringSync();

ImportItem byTitle(List<ImportItem> items, String title) => items.firstWhere((i) => i.title == title);

void main() {
  group('MCP parsers', () {
    test('variables come over switched off and unticked', () {
      final gh = byTitle(parseClaudeMcp(fx('claude.json')), 'github');
      expect(gh.mcp!.enabled, isFalse);
      expect(gh.checked, isFalse);
      expect(gh.notes.join(), contains('variables'));
    });

    test('a floor command is not importable', () {
      final d = byTitle(parseClaudeMcp(fx('claude.json')), 'danger');
      expect(d.selectable, isFalse);
      expect(d.unavailable, startsWith('Blocked'));
    });

    test('every local command waits for consent, whatever the tool', () {
      final all = [
        ...parseClaudeMcp(fx('claude.json'), projects: {'/work/app'}),
        ...parseProjectMcpJson(fx('mcp.json'), project: '/p'),
        ...parseCursorMcp(fx('cursor_mcp.json')),
        ...parseOpenCodeMcp(fx('opencode.jsonc')),
        ...parseCodexMcp(fx('codex_config.toml')),
      ];
      final local = all.where((i) => i.mcp?.transport == McpTransport.stdio).toList();
      expect(local, isNotEmpty);
      for (final i in local) {
        expect(i.mcp!.approved, isNull);
        expect(i.mcp!.needsConsent, isTrue);
        expect(i.mcp!.active, isFalse);
      }
    });
  });

  group('agents', () {
    test('bypassPermissions is not carried', () {
      final item = mapClaudeAgent('fixer.md', fx('claude_agent_bypass.md'));
      final def = AgentDefinition.parse(item.agentText!, fileName: 'fixer.md', source: AgentSource.global);
      expect(def.errors, isEmpty);
      expect(def.mode, isNull);
      expect(item.notes.join(), contains('bypassPermissions'));
    });
  });

  group('malformed input', () {
    test('an inline [mcp_servers] table is read', () {
      final p = parseCodexToml('[mcp_servers]\nc7 = { command = "npx", args = ["-y", "x"] }\n');
      expect(p.servers['c7']!['command'], 'npx');
    });

    test('an agent with hidden text is flagged and unticked', () {
      final item = mapClaudeAgent('a.md', '---\nname: a\ndescription: d\n---\nhi\u200B there', project: '/p');
      expect(item.notes.join(' '), contains('hidden'));
      expect(item.checked, isFalse);
    });
  });
}
