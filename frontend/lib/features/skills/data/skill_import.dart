import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';

import '../domain/skill_format.dart';

/// A file offered for import, from a folder or a zip.
@immutable
final class SkillFile {
  const SkillFile(this.path, {required this.size, this.kind = SkillEntryKind.file, this.read});

  /// `/`-separated, relative to where the import started.
  final String path;
  final int size;
  final SkillEntryKind kind;

  /// The bytes (files only).
  final Future<Uint8List> Function()? read;
}

/// One skill found in an import: its folder name, the strict check, and its
/// files relative to the skill folder.
@immutable
final class ImportCandidate {
  const ImportCandidate({required this.dirName, required this.check, required this.files});

  final String dirName;
  final SkillCheck check;
  final List<SkillFile> files;
  bool get ok => check.report.ok;
}

/// The skills in [files]: every folder holding a `SKILL.md` (nested skills
/// belong to the outer one). A `SKILL.md` at the top takes its folder name
/// from the skill's name, else [fallbackName].
Future<List<ImportCandidate>> findImportCandidates(List<SkillFile> files, {required String fallbackName}) async {
  final kept = [
    for (final f in files)
      if (!SkillRules.ignored(f.path)) f,
  ];
  final roots = <String>{
    for (final f in kept)
      if (f.kind == SkillEntryKind.file && (f.path == 'SKILL.md' || f.path.endsWith('/SKILL.md')))
        f.path.length == 8 ? '' : f.path.substring(0, f.path.length - 9),
  };
  bool inside(String path, String root) => root.isEmpty || path == root || path.startsWith('$root/');
  final outer = [
    for (final r in roots)
      if (!roots.any((o) => o != r && o.length < r.length && inside(r, o))) r,
  ]..sort();

  final out = <ImportCandidate>[];
  for (final root in outer) {
    final own = <SkillFile>[
      for (final f in kept)
        if (f.path != root && inside(f.path, root))
          SkillFile(
            root.isEmpty ? f.path : f.path.substring(root.length + 1),
            size: f.size,
            kind: f.kind,
            read: f.read,
          ),
    ];
    final md = own.where((f) => f.path == 'SKILL.md').first;
    String? text;
    if (md.size <= SkillRules.maxSkillMdBytes && md.read != null) {
      text = utf8.decode(await md.read!(), allowMalformed: true);
    } else {
      text = 'x' * (SkillRules.maxSkillMdBytes + 1); // reported as too large
    }
    var dirName = root.isEmpty ? fallbackName : root.split('/').last;
    if (root.isEmpty) {
      try {
        final name = parseFrontMatter(text).fields['name'];
        if (name is String && name.trim().isNotEmpty) dirName = name.trim();
      } on FormatException {
        // The check below reports it.
      }
    }
    final entries = <SkillEntry>[];
    for (final f in own) {
      var head = const <int>[];
      if (f.kind == SkillEntryKind.file && f.read != null && f.size >= 2 && f.size <= SkillRules.maxFileBytes) {
        final bytes = await f.read!();
        head = bytes.length > 4 ? bytes.sublist(0, 4) : bytes;
      }
      entries.add(SkillEntry(f.path, size: f.size, kind: f.kind, head: head));
    }
    out.add(
      ImportCandidate(
        dirName: dirName,
        check: checkSkill(dirName: dirName, skillMd: text, entries: entries),
        files: own,
      ),
    );
  }
  return out;
}

/// The entries of a zip, without unpacking anything yet. Sizes are the
/// declared ones, so an oversized archive is refused before it is inflated.
List<SkillFile> zipFiles(Uint8List bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  return [
    for (final f in archive.files)
      if (f.name.isNotEmpty)
        SkillFile(
          f.name.endsWith('/') ? f.name.substring(0, f.name.length - 1) : f.name,
          size: f.isFile ? f.size : 0,
          kind: f.isSymbolicLink
              ? SkillEntryKind.link
              : f.isFile
              ? SkillEntryKind.file
              : SkillEntryKind.directory,
          read: f.isFile ? () async => f.readBytes() ?? Uint8List(0) : null,
        ),
  ];
}
