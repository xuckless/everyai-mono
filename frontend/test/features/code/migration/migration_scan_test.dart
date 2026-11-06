import 'dart:io';

import 'package:every_ai/features/agents/domain/agent_definition.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/mcp_servers.dart';
import 'package:every_ai/features/code/migration/migration_scan.dart';
import 'package:flutter_test/flutter_test.dart';

String fx(String name) => File('test/fixtures/migration/$name').readAsStringSync();

ImportItem byTitle(List<ImportItem> items, String title) => items.firstWhere((i) => i.title == title);

void main() {
  group('parseCodexToml', () {
    final parsed = parseCodexToml(fx('codex_config.toml'));

    test('reads only mcp_servers tables', () {
      expect(parsed.servers.keys, unorderedEquals(['context7', 'my.server', 'figma']));
    });

    test('strings, arrays over lines, comments, quoted key, sub-table and inline table', () {
      expect(parsed.servers['context7']!['args'], ['-y', '@upstash/context7-mcp']);
      expect(parsed.servers['my.server']!['args'], ['tool', '--flag']);
      expect(parsed.servers['my.server']!['env'], {'API_KEY': 'abc', 'MODE': 'literal'});
      expect(parsed.servers['figma']!['http_headers'], {'X-Region': 'us', 'X-Other': '1'});
    });

    test('a table it cannot read is reported and left out', () {
      expect(parsed.bad, ['broken']);
      expect(parsed.servers.containsKey('broken'), isFalse);
    });
  });

  group('MCP parsers', () {
    test('Claude user, project and local scope', () {
      final items = parseClaudeMcp(fx('claude.json'), projects: {'/work/app'});
      expect(
        items.map((i) => i.title),
        containsAll(['github', 'fs', 'docs', 'events', 'live', 'bad-name-', 'local-db']),
      );
      expect(items.any((i) => i.title == 'nope'), isFalse, reason: 'a project we do not know');
      expect(byTitle(items, 'local-db').scope, '/work/app');
      expect(byTitle(items, 'docs').mcp!.transport, McpTransport.http);
      expect(byTitle(items, 'docs').mcp!.headers, {'X-Team': 'core'});
      expect(byTitle(items, 'events').mcp!.transport, McpTransport.sse);
      expect(byTitle(items, 'events').notes.join(), contains('oauth'));
      expect(byTitle(items, 'live').unavailable, contains('WebSocket'));
      expect(byTitle(items, 'bad-name-').notes.first, contains('Renamed'));
    });

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

    test('project .mcp.json is project scope and unticked', () {
      final items = parseProjectMcpJson(fx('mcp.json'), project: '/work/app');
      expect(items.every((i) => i.scope == '/work/app' && !i.checked), isTrue);
      expect(byTitle(items, 'team').mcp!.transport, McpTransport.http);
    });

    test('Cursor', () {
      final items = parseCursorMcp(fx('cursor_mcp.json'));
      expect(byTitle(items, 'github').mcp!.command, 'node');
      expect(byTitle(items, 'remote').mcp!.headers['Authorization'], 'Bearer abc');
      expect(byTitle(items, 'remote').notes.join(), contains('key or token'));
    });

    test('OpenCode: comments, trailing commas, // inside a string, command array', () {
      final items = parseOpenCodeMcp(fx('opencode.jsonc'));
      final local = byTitle(items, 'local-one').mcp!;
      expect(local.command, 'bun');
      expect(local.args, ['x', 'my-mcp']);
      expect(local.env, {'A': '1'});
      expect(local.enabled, isFalse);
      expect(byTitle(items, 'sentry').mcp!.url, 'https://mcp.sentry.dev/mcp');
      expect(stripJsonc('{"u": "http://a//b" // c\n}'), '{"u": "http://a//b" \n}');
    });

    test('Codex: command, bearer variable, headers, bad table', () {
      final items = parseCodexMcp(fx('codex_config.toml'));
      expect(byTitle(items, 'context7').mcp!.args, ['-y', '@upstash/context7-mcp']);
      expect(byTitle(items, 'my-server').mcp!.env['API_KEY'], 'abc');
      final figma = byTitle(items, 'figma').mcp!;
      expect(figma.headers['Authorization'], r'Bearer ${FIGMA_TOKEN}');
      expect(figma.enabled, isFalse, reason: 'variable');
      expect(byTitle(items, 'broken').unavailable, contains("Couldn't read"));
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

    test('merge: the same server in two tools is one row, different ones are told apart', () {
      final merged = mergeMcpItems([...parseClaudeMcp(fx('claude.json')), ...parseCursorMcp(fx('cursor_mcp.json'))]);
      final fs = merged.where((i) => i.title == 'fs').toList();
      expect(fs, hasLength(1));
      expect(fs.single.source, 'Claude Code, Cursor');
      expect(merged.where((i) => i.title == 'github'), hasLength(1));
      expect(merged.map((i) => i.title), contains('github-cursor'));
      expect(merged.map((i) => i.mcp?.name).whereType<String>().every(McpServer.namePattern.hasMatch), isTrue);
    });
  });

  group('commands', () {
    test('Claude arguments shift from 0-based to 1-based', () {
      final item = mapClaudeCommand('review.md', fx('claude_cmds/review.md'));
      final c = item.command!;
      expect(c.name, 'review');
      expect(c.body, r'Review $1 with focus on $2. Everything: $ARGUMENTS');
      expect(c.expand('a.dart perf'), 'Review a.dart with focus on perf. Everything: a.dart perf');
      expect(c.args, '<file> <focus>');
      expect(c.model, isNull);
      expect(item.notes.join(), allOf(contains('allowed-tools'), contains('sonnet')));
    });

    test('inline shell and indexed arguments are refused with a reason', () {
      expect(mapClaudeCommand('bash.md', fx('claude_cmds/bash.md')).unavailable, contains('shell'));
      expect(mapClaudeCommand('indexed.md', fx('claude_cmds/indexed.md')).unavailable, contains('ARGUMENTS[N]'));
      expect(mapClaudeCommand('x.md', r'Use $9').unavailable, contains('more than 9'));
    });

    test('nested path is flattened, odd names are cleaned', () {
      expect(mapClaudeCommand('git/Pr Review.md', 'Do it').command!.name, 'git-pr-review');
      expect(mapClaudeCommand('...md', 'Do it').unavailable, isNotNull);
    });

    test('Cursor commands are plain Markdown', () {
      final item = mapCursorCommand('explain.md', fx('cursor_cmds/explain.md'));
      expect(item.command!.description, 'Explain this code');
      expect(item.command!.body, contains('Explain the selected code'));
    });

    test('project commands start unticked', () {
      expect(mapCursorCommand('x.md', 'Hi', project: '/p').checked, isFalse);
      expect(mapCursorCommand('x.md', 'Hi').checked, isTrue);
    });
  });

  group('agents', () {
    test('Claude agent becomes an EveryAI agent file that parses clean', () {
      final item = mapClaudeAgent('code-reviewer.md', fx('claude_agent.md'));
      expect(item.agentName, 'code-reviewer');
      final def = AgentDefinition.parse(item.agentText!, fileName: 'code-reviewer.md', source: AgentSource.global);
      expect(def.errors, isEmpty);
      expect(def.description, 'Reviews diffs for bugs. Use after edits.');
      expect(def.mode, AgentMode.plan);
      expect(def.model, isNull);
      expect(def.tools, isNull);
      expect(def.prompt, 'You review code. Be brief.');
      expect(item.notes.join(), allOf(contains('tools'), contains('model'), contains('skills')));
    });

    test('bypassPermissions is not carried', () {
      final item = mapClaudeAgent('fixer.md', fx('claude_agent_bypass.md'));
      final def = AgentDefinition.parse(item.agentText!, fileName: 'fixer.md', source: AgentSource.global);
      expect(def.errors, isEmpty);
      expect(def.mode, isNull);
      expect(item.notes.join(), contains('bypassPermissions'));
    });

    test('no description is refused', () {
      expect(mapClaudeAgent('x.md', '---\nname: x\n---\nhi').unavailable, contains('description'));
    });
  });

  group('rules', () {
    test('marks the files EveryAI reads', () {
      final items = findRuleFiles([
        '/p/CLAUDE.md',
        '/p/AGENTS.md',
        '/p/GEMINI.md',
        '/p/.cursor/rules/style.mdc',
        '/p/.cursorrules',
        '/p/README.md',
      ], project: '/p');
      expect(items.map((i) => (i.title, i.used)), [
        ('CLAUDE.md', false), // AGENTS.md in the same folder wins
        ('AGENTS.md', true),
        ('GEMINI.md', false),
        ('.cursor/rules/style.mdc', false),
        ('.cursorrules', false),
      ]);
      expect(items.every((i) => !i.selectable), isTrue);
    });

    test('the user-level CLAUDE.md is not read', () {
      final item = findRuleFiles(['/home/u/.claude/CLAUDE.md']).single;
      expect(item.used, isFalse);
      expect(item.detail, contains('AGENTS.md'));
    });
  });

  group('malformed input', () {
    test('a list-valued command or numeric url does not throw', () {
      const json = '{"mcpServers":{"a":{"command":["npx","x"]},"b":{"type":1,"url":5},"ok":{"command":"npx"}}}';
      final items = parseProjectMcpJson(json, project: '/p');
      expect(items.map((i) => i.title), containsAll(['a', 'b', 'ok']));
      expect(parseCursorMcp(json).length, 3);
    });

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
