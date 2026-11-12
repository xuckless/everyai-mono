import 'dart:io';

import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/features/agents/agents_providers.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/mcp_providers.dart';
import 'package:every_ai/features/code/migration/migration_files.dart';
import 'package:every_ai/features/code/migration/migration_providers.dart';
import 'package:every_ai/features/code/migration/migration_scan.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

String fx(String name) => File('test/fixtures/migration/$name').readAsStringSync();

void put(String path, String text) {
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(text);
}

Map<String, String> snapshot(Directory dir) => {
  for (final f in dir.listSync(recursive: true).whereType<File>()) f.path: f.readAsStringSync(),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late String home;
  late String project;
  late ProviderContainer c;
  late String projectId;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('migration_apply');
    home = '${tmp.path}/home';
    project = '${tmp.path}/work/app';
    put('$home/.claude.json', fx('claude.json'));
    put('$home/.cursor/mcp.json', fx('cursor_mcp.json'));
    put('$project/.mcp.json', fx('mcp.json'));
    put('$project/.claude/commands/review.md', fx('claude_cmds/review.md'));
    put('$project/.claude/agents/code-reviewer.md', fx('claude_agent.md'));
    c = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(Preferences.inMemory()),
        migrationRootsProvider.overrideWith((ref) => migrationRoots({'HOME': home})),
      ],
    );
    projectId = c.read(codeProjectsProvider.notifier).add(project).id;
    c.listen(migrationScanProvider, (_, _) {}); // the sheet being open
  });

  tearDown(() {
    c.dispose();
    tmp.deleteSync(recursive: true);
  });

  Future<List<ImportItem>> scan() => c.read(migrationScanProvider.future);
  Future<List<String>> apply(List<ImportItem> items) => c.read(importApplierProvider)(items);

  test('nothing chosen writes nothing', () async {
    await scan();
    expect(await apply(const []), isEmpty);
    expect(c.read(codeMcpServersProvider).global, isEmpty);
  });

  test('a chosen MCP server lands in its scope, unapproved, and never replaces a name', () async {
    final items = await scan();
    final docs = items.firstWhere((i) => i.title == 'docs');
    final team = items.firstWhere((i) => i.title == 'team');
    final fs = items.firstWhere((i) => i.title == 'fs' && i.scope == null);
    expect(await apply([docs, team, fs]), [
      'docs: imported.',
      'team: imported.',
      'fs: imported. You approve the command in MCP servers before it runs.',
    ]);
    final store = c.read(codeMcpServersProvider);
    expect(store.global.map((s) => s.name), ['docs', 'fs']);
    expect(store.projects[projectId]!.map((s) => s.name), ['team']);
    expect(store.global.last.needsConsent, isTrue);
    expect(store.global.last.approved, isNull);

    // The user edited it meanwhile; importing again must not overwrite.
    c.read(codeMcpServersProvider.notifier).put(store.global.first.copyWith(description: 'mine'));
    expect(await apply([docs]), ['docs: already in EveryAI, left as it is.']);
    expect(c.read(codeMcpServersProvider).global.firstWhere((s) => s.name == 'docs').description, 'mine');
    // A fresh scan marks them.
    c.invalidate(migrationScanProvider);
    final again = await scan();
    expect(again.firstWhere((i) => i.title == 'docs').unavailable, 'Already in EveryAI.');
    expect(again.firstWhere((i) => i.title == 'docs').selectable, isFalse);
  });

  test('an imported project agent still needs the normal trust review', () async {
    final agent = (await scan()).firstWhere((i) => i.kind == ImportKind.agent);
    await apply([agent]);
    final a = (await c.read(agentLibraryProvider.future)).firstWhere((x) => x.name == 'code-reviewer');
    expect(c.read(agentLibrarySettingsProvider).trustedNow(a), isFalse);
    c.invalidate(migrationScanProvider);
    expect((await scan()).firstWhere((i) => i.kind == ImportKind.agent).unavailable, 'Already in EveryAI.');
  });

  test('the other tools\' folders are byte for byte the same after an import', () async {
    final items = await scan();
    final theirs = [Directory(home), Directory('$project/.claude'), File('$project/.mcp.json')];
    Map<String, String> snap() => {
      for (final e in theirs)
        if (e is Directory) ...snapshot(e) else e.path: (e as File).readAsStringSync(),
    };
    final before = snap();
    await apply(items.where((i) => i.selectable).toList());
    expect(snap(), before);
  });
}
