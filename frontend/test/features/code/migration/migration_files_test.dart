import 'dart:io';

import 'package:every_ai/features/code/migration/migration_files.dart';
import 'package:every_ai/features/code/migration/migration_scan.dart';
import 'package:flutter_test/flutter_test.dart';

String fx(String name) => File('test/fixtures/migration/$name').readAsStringSync();

void put(String path, String text) {
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(text);
}

/// Every file under [dir] with its text, to compare before and after.
Map<String, String> snapshot(Directory dir) => {
  for (final f in dir.listSync(recursive: true).whereType<File>()) f.path: f.readAsStringSync(),
};

void main() {
  group('migrationRoots', () {
    test('defaults under HOME', () {
      final r = migrationRoots({'HOME': '/home/a'});
      expect(r.claudeDir, '/home/a/.claude');
      expect(r.claudeJson, '/home/a/.claude.json');
      expect(r.cursorDir, '/home/a/.cursor');
      expect(r.codexDir, '/home/a/.codex');
      expect(r.openCodeDir, '/home/a/.config/opencode');
    });

    test('CLAUDE_CONFIG_DIR, CODEX_HOME and XDG_CONFIG_HOME win', () {
      final r = migrationRoots({
        'HOME': '/home/a',
        'CLAUDE_CONFIG_DIR': '/c/claude/',
        'CODEX_HOME': '/c/codex',
        'XDG_CONFIG_HOME': '/c/xdg',
      });
      expect(r.claudeDir, '/c/claude');
      expect(r.claudeJson, '/c/claude/.claude.json');
      expect(r.codexDir, '/c/codex');
      expect(r.openCodeDir, '/c/xdg/opencode');
    });

    test('Windows-style home from USERPROFILE', () {
      final r = migrationRoots({'USERPROFILE': r'C:\Users\Ali'});
      expect(r.claudeDir, r'C:\Users\Ali/.claude');
      expect(r.openCodeDir, r'C:\Users\Ali/.config/opencode');
    });

    test('no home gives nothing to read', () {
      final r = migrationRoots(const {});
      expect(r.claudeDir, isNull);
      expect(r.claudeJson, isNull);
    });
  });

  group('scanOtherTools', () {
    late Directory tmp;
    late String home;
    late String project;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('migration_scan');
      home = '${tmp.path}/home';
      project = '${tmp.path}/work/app';
      put('$home/.claude.json', fx('claude.json').replaceAll('/work/app', project));
      put('$home/.claude/commands/review.md', fx('claude_cmds/review.md'));
      put('$home/.claude/commands/git/pr.md', 'Open a PR');
      put('$home/.claude/agents/code-reviewer.md', fx('claude_agent.md'));
      put('$home/.claude/skills/lint/SKILL.md', '---\nname: lint\ndescription: Lints\n---\nbody');
      put('$home/.claude/skills/notes/README.md', 'not a skill');
      put('$home/.claude/CLAUDE.md', 'Be nice');
      put('$home/.cursor/mcp.json', fx('cursor_mcp.json'));
      put('$home/.cursor/commands/explain.md', fx('cursor_cmds/explain.md'));
      put('$home/.codex/config.toml', fx('codex_config.toml'));
      put('$home/.config/opencode/opencode.jsonc', fx('opencode.jsonc'));
      put('$project/.mcp.json', fx('mcp.json'));
      put('$project/AGENTS.md', 'rules');
      put('$project/GEMINI.md', 'rules');
      put('$project/.cursor/rules/style.mdc', 'rules');
      put('$project/.claude/commands/ship.md', 'Ship it');
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test('finds each kind in the right scope and changes nothing', () async {
      final before = snapshot(tmp);
      final items = await scanOtherTools(migrationRoots({'HOME': home}), [project]);
      expect(snapshot(tmp), before, reason: 'the other tools\' folders are only read');

      String? at(ImportKind k, String title) => items.where((i) => i.kind == k && i.title == title).firstOrNull?.scope;
      expect(items.where((i) => i.kind == ImportKind.mcp && i.title == 'local-db').single.scope, project);
      expect(at(ImportKind.mcp, 'context7'), isNull);
      expect(items.where((i) => i.title == 'fs' && i.scope == null).single.source, 'Claude Code, Cursor');
      expect(items.where((i) => i.title == '/team'), isEmpty);
      expect(items.where((i) => i.kind == ImportKind.mcp && i.title == 'team').single.scope, project);
      expect(
        items.map((i) => i.title),
        containsAll(['/review', '/git-pr', '/explain', '/ship', 'code-reviewer', 'lint']),
      );
      expect(items.any((i) => i.title == 'notes'), isFalse);
      expect(items.where((i) => i.title == '/ship').single.scope, project);
      final rules = items.where((i) => i.kind == ImportKind.rule).map((i) => (i.title, i.used)).toList();
      expect(rules, containsAll([('CLAUDE.md', false), ('AGENTS.md', true), ('GEMINI.md', false)]));
      expect(rules.any((r) => r.$1.endsWith('style.mdc')), isTrue);
    });

    test('missing folders give nothing', () async {
      expect(await scanOtherTools(migrationRoots({'HOME': '${tmp.path}/nowhere'}), const []), isEmpty);
    });
  });
}
