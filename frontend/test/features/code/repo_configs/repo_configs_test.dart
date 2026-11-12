import 'dart:io';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/features/code/domain/cli_repo_configs.dart';
import 'package:every_ai/features/code/repo_configs/repo_config_note.dart';
import 'package:every_ai/features/code/repo_configs/repo_config_scan.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A project's files in memory: path → text; a path ending in `/` is a folder.
final class _Tree implements RepoTree {
  _Tree(this.files);
  final Map<String, String> files;

  @override
  String? read(String path) => files[path];

  @override
  bool isDir(String path) => files.keys.any((k) => k.startsWith('$path/'));
}

void main() {
  List<String> paths(RepoConfigCli cli, Map<String, String> files) => [
    for (final f in cliRepoConfigs(cli, _Tree(files))) f.path,
  ];

  test('Gemini and Qwen: settings that widen what runs unasked, policies and extensions; harmless keys are not', () {
    expect(paths(RepoConfigCli.gemini, {'.gemini/settings.json': '{"ui": {}, "model": {}, "general": {}}'}), isEmpty);
    expect(
      paths(RepoConfigCli.gemini, {
        '.gemini/settings.json': '{"ui": {}, "mcpServers": {"x": {"command": "evil"}}}',
        '.gemini/policies/a.toml': '',
        '.gemini/extensions/e/gemini-extension.json': '{}',
      }),
      ['.gemini/settings.json', '.gemini/policies/', '.gemini/extensions/'],
    );
    final what = cliRepoConfigs(
      RepoConfigCli.qwen,
      _Tree({'.qwen/settings.json': '{"tools": {"allowed": ["run_shell_command"]}}'}),
    ).single;
    expect(what.path, '.qwen/settings.json');
    expect(what.what, contains('"tools"'));
    // Gemini's own folder isn't Qwen's.
    expect(paths(RepoConfigCli.qwen, {'.gemini/settings.json': '{"mcpServers": {}}'}), isEmpty);
  });

  group('the note', () {
    late Directory tmp;
    late AppDatabase db;
    late ProviderContainer c;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('repo-configs');
      db = AppDatabase(NativeDatabase.memory());
      c = ProviderContainer(overrides: [preferencesProvider.overrideWithValue(await Preferences.load(db))]);
    });
    tearDown(() async {
      c.dispose();
      await db.close();
      await tmp.delete(recursive: true);
    });

    test('accepted files are not asked about again; a changed file is; Cancel asks again next time', () async {
      File('${tmp.path}/.cursor/hooks.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{"hooks": {}}');
      final first = (await scanRepoConfigs(RepoConfigCli.cursor, tmp.path))!;
      final notes = c.read(repoConfigNotesProvider.notifier);
      final key = repoConfigNoteKey('p1', 'cursor');
      expect(notes.of(key), isA<RepoConfigUnseen>());
      expect(notes.of(key).asksFor(first.digest), isTrue);

      // Cancel: unseen again.
      notes
        ..show(key, first.digest)
        ..dismiss(key);
      expect(notes.of(key).asksFor(first.digest), isTrue);

      // Continue: kept, also across a restart (preferences).
      notes
        ..show(key, first.digest)
        ..accept(key);
      expect(notes.of(key).asksFor(first.digest), isFalse);
      c.invalidate(repoConfigNotesProvider);
      expect(c.read(repoConfigNotesProvider.notifier).of(key).asksFor(first.digest), isFalse);
      // Another project or harness is asked on its own.
      expect(notes.of(repoConfigNoteKey('p2', 'cursor')).asksFor(first.digest), isTrue);

      File('${tmp.path}/.cursor/hooks.json').writeAsStringSync('{"hooks": {"beforeShellExecution": []}}');
      final changed = (await scanRepoConfigs(RepoConfigCli.cursor, tmp.path))!;
      expect(changed.digest, isNot(first.digest));
      expect(c.read(repoConfigNotesProvider.notifier).of(key).asksFor(changed.digest), isTrue);
    });
  });
}
