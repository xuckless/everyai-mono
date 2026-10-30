import 'dart:convert';
import 'dart:io';

import 'learn_sources.dart' show LearnDocument, maxLearnChars, maxLearnFiles;

bool isFolder(String path) => FileSystemEntity.isDirectorySync(path);

String expandHome(String path) {
  final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null || !(path == '~' || path.startsWith('~/'))) return path;
  return '$home${path.substring(1)}';
}

Future<bool> holdsSkills(String path) async {
  if (File('$path/SKILL.md').existsSync()) return true;
  final dir = Directory(path);
  if (!dir.existsSync()) return false;
  await for (final e in dir.list(followLinks: false)) {
    if (e is Directory && File('${e.path}/SKILL.md').existsSync()) return true;
  }
  return false;
}

const _skipDirs = {
  'node_modules',
  'build',
  'dist',
  'out',
  'target',
  'vendor',
  '__pycache__',
  'venv',
  '.venv',
  'Pods',
  'DerivedData',
};

const _textExtensions = {
  'md',
  'markdown',
  'txt',
  'rst',
  'adoc',
  'org',
  'yaml',
  'yml',
  'toml',
  'json',
  'ini',
  'cfg',
  'sh',
  'bash',
  'zsh',
  'fish',
  'ps1',
  'py',
  'rb',
  'js',
  'mjs',
  'ts',
  'tsx',
  'jsx',
  'dart',
  'go',
  'rs',
  'zig',
  'java',
  'kt',
  'swift',
  'c',
  'h',
  'cc',
  'cpp',
  'hpp',
  'cs',
  'php',
  'sql',
  'html',
  'css',
  'scss',
  'xml',
  'gradle',
  'make',
  'mk',
  'tf',
  'lua',
};

/// Lower sorts first: instructions and docs before code.
int _rank(String rel) {
  final name = rel.split('/').last.toLowerCase();
  if (name == 'skill.md') return 0;
  if (name.startsWith('readme')) return 1;
  if (name == 'agents.md' || name == 'claude.md' || name == 'contributing.md') return 2;
  final ext = name.contains('.') ? name.split('.').last : '';
  if (const {'md', 'markdown', 'txt', 'rst', 'adoc', 'org'}.contains(ext)) return 3;
  return 4;
}

bool _wanted(String name) {
  final lower = name.toLowerCase();
  if (const {'makefile', 'dockerfile', 'justfile', 'procfile'}.contains(lower)) return true;
  if (!lower.contains('.')) return false;
  if (lower.endsWith('.lock') || lower.endsWith('-lock.json') || lower.endsWith('.min.js')) return false;
  return _textExtensions.contains(lower.split('.').last);
}

Future<List<LearnDocument>> readFolder(String path) async {
  final root = Directory(path);
  if (!root.existsSync()) return const [];
  final found = <(String rel, File file)>[];
  Future<void> walk(Directory dir, String prefix, int depth) async {
    if (depth > 4 || found.length > maxLearnFiles * 8) return;
    final entries = await dir.list(followLinks: false).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final e in entries) {
      final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (name.startsWith('.')) continue;
      final rel = prefix.isEmpty ? name : '$prefix/$name';
      if (e is Directory) {
        if (!_skipDirs.contains(name)) await walk(e, rel, depth + 1);
      } else if (e is File && _wanted(name)) {
        found.add((rel, e));
      }
    }
  }

  await walk(root, '', 0);
  found.sort((a, b) {
    final r = _rank(a.$1).compareTo(_rank(b.$1));
    if (r != 0) return r;
    final d = '/'.allMatches(a.$1).length.compareTo('/'.allMatches(b.$1).length);
    return d != 0 ? d : a.$1.compareTo(b.$1);
  });
  final out = <LearnDocument>[];
  var total = 0;
  for (final (rel, file) in found) {
    if (out.length >= maxLearnFiles || total >= maxLearnChars) break;
    try {
      if (await file.length() > 256 * 1024) continue;
      final bytes = await file.readAsBytes();
      if (bytes.contains(0)) continue; // binary
      var text = utf8.decode(bytes, allowMalformed: true).trim();
      if (text.isEmpty) continue;
      final room = maxLearnChars - total;
      if (text.length > room) text = text.substring(0, room);
      out.add((path: rel, text: text));
      total += text.length;
    } on FileSystemException {
      continue;
    }
  }
  return out;
}
