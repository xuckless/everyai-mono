// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';

import 'migration_roots.dart';
import 'migration_scan.dart';

const _maxConfigBytes = 32 << 20; // ~/.claude.json grows with use
const _maxTextBytes = 256 * 1024;

String? _in(String? dir, String rest) => dir == null ? null : '$dir/$rest';

Future<String?> _read(String? path, {int max = _maxTextBytes}) async {
  if (path == null) return null;
  try {
    final f = File(path);
    if (await f.length() > max) return null;
    return await f.readAsString();
  } on Object {
    return null;
  }
}

/// The `.md` files under [dir] (links not followed, at most [depth] folders down) as paths relative to [dir].
Future<List<String>> _markdown(String? dir, {int depth = 3}) async {
  if (dir == null) return const [];
  final out = <String>[];
  Future<void> walk(String path, String rel, int left) async {
    try {
      await for (final e in Directory(path).list(followLinks: false)) {
        final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (e is File && name.endsWith('.md')) {
          out.add(rel.isEmpty ? name : '$rel/$name');
        } else if (e is Directory && left > 0) {
          await walk(e.path, rel.isEmpty ? name : '$rel/$name', left - 1);
        }
      }
    } on Object {
      return;
    }
  }

  await walk(dir, '', depth);
  out.sort();
  return out;
}

Future<List<ImportItem>> _commands(String? dir, {required bool claude, String? project}) async {
  final out = <ImportItem>[];
  for (final rel in await _markdown(dir)) {
    final text = await _read('$dir/$rel');
    if (text == null) continue;
    out.add(claude ? mapClaudeCommand(rel, text, project: project) : mapCursorCommand(rel, text, project: project));
  }
  return out;
}

Future<List<ImportItem>> _agents(String? dir, {String? project}) async {
  final out = <ImportItem>[];
  for (final rel in await _markdown(dir)) {
    final text = await _read('$dir/$rel');
    if (text != null) out.add(mapClaudeAgent(rel, text, project: project));
  }
  return out;
}

/// One row per `~/.claude/skills/<name>/SKILL.md`; the strict check runs when they are imported.
Future<List<ImportItem>> _skills(String? dir) async {
  if (dir == null) return const [];
  final out = <ImportItem>[];
  try {
    await for (final e in Directory(dir).list(followLinks: false)) {
      // Skill installers link the folders in; the strict check on import still looks inside.
      final isDir = e is Directory || e is Link && FileSystemEntity.isDirectorySync(e.path);
      if (!isDir || !File('${e.path}/SKILL.md').existsSync()) continue;
      final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      out.add(ImportItem(kind: ImportKind.skill, source: toolClaude, title: name, path: e.path, checked: true));
    }
  } on Object {
    return out;
  }
  out.sort((a, b) => a.title.compareTo(b.title));
  return out;
}

Future<List<String>> _ruleCandidates(String dir) async => [
  for (final n in const ['CLAUDE.md', 'AGENTS.md', 'AGENTS.override.md', 'GEMINI.md', '.cursorrules'])
    if (File('$dir/$n').existsSync()) '$dir/$n',
  for (final f in await _listFiles('$dir/.cursor/rules'))
    if (f.endsWith('.mdc') || f.endsWith('.md')) f,
];

Future<List<String>> _listFiles(String dir) async {
  try {
    return [
      await for (final e in Directory(dir).list(followLinks: false))
        if (e is File) e.path,
    ]..sort();
  } on Object {
    return const [];
  }
}

Future<String?> _firstExisting(String? dir, List<String> names) async {
  if (dir == null) return null;
  for (final n in names) {
    final t = await _read('$dir/$n');
    if (t != null) return t;
  }
  return null;
}

Future<List<ImportItem>> scan(MigrationRoots roots, List<String> projectPaths) async {
  final items = <ImportItem>[];
  final projects = projectPaths.toSet();

  // The user's own config in each tool.
  if (await _read(roots.claudeJson, max: _maxConfigBytes) case final t?) {
    items.addAll(parseClaudeMcp(t, projects: projects));
  }
  if (await _read(_in(roots.cursorDir, 'mcp.json')) case final t?) items.addAll(parseCursorMcp(t));
  if (await _read(_in(roots.codexDir, 'config.toml')) case final t?) items.addAll(parseCodexMcp(t));
  if (await _firstExisting(roots.openCodeDir, ['opencode.jsonc', 'opencode.json']) case final t?) {
    items.addAll(parseOpenCodeMcp(t));
  }
  items.addAll(await _commands(_in(roots.claudeDir, 'commands'), claude: true));
  items.addAll(await _commands(_in(roots.cursorDir, 'commands'), claude: false));
  items.addAll(await _agents(_in(roots.claudeDir, 'agents')));
  items.addAll(await _skills(_in(roots.claudeDir, 'skills')));
  if (_in(roots.claudeDir, 'CLAUDE.md') case final f? when File(f).existsSync()) items.addAll(findRuleFiles([f]));

  // What sits in each project folder.
  for (final p in projects) {
    if (await _read('$p/.mcp.json') case final t?) items.addAll(parseProjectMcpJson(t, project: p));
    if (await _read('$p/.cursor/mcp.json') case final t?) items.addAll(parseCursorMcp(t, project: p));
    if (await _firstExisting(p, ['opencode.jsonc', 'opencode.json']) case final t?) {
      items.addAll(parseOpenCodeMcp(t, project: p));
    }
    items.addAll(await _commands('$p/.claude/commands', claude: true, project: p));
    items.addAll(await _commands('$p/.cursor/commands', claude: false, project: p));
    items.addAll(await _agents('$p/.claude/agents', project: p));
    items.addAll(findRuleFiles(await _ruleCandidates(p), project: p));
  }
  return [
    ...mergeMcpItems(items.where((i) => i.kind == ImportKind.mcp).toList()),
    ...items.where((i) => i.kind != ImportKind.mcp),
  ];
}
