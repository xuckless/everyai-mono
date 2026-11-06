// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';
import 'dart:io';

import '../harness/everyai/project_notes_io.dart' show notesLinkProblem;
import '../harness/everyai/scrub.dart' show Scrubber;
import '../settings/settings.dart' show excludeFromGit;
import 'runtime_profiles.dart';

/// One write at a time per file: several sessions can share a project.
final _chains = <String, Future<void>>{};
final _excluded = <String>{};

/// Adds [took] for [command] in [dir] to [projectRoot]'s profiles. Never throws.
Future<void> recordRuntime(String projectRoot, String command, String dir, Duration took) {
  final path = '$projectRoot/$runtimeProfilesPath';
  final next = (_chains[path] ?? Future<void>.value())
      .then((_) => _record(projectRoot, path, command, dir, took))
      .catchError((Object _) {});
  _chains[path] = next;
  return next;
}

Future<void> _record(String projectRoot, String path, String command, String dir, Duration took) async {
  // The briefing goes to other vendors' agents: nothing from the user's environment or .env files.
  if (Scrubber.forProject(projectRoot).leak(command) != null) return;
  final tmp = File('$path.$pid.tmp');
  // A linked .everyai/ (or file) could point the write anywhere; a tracked file is the repository's, not ours.
  if (notesLinkProblem(projectRoot, path) != null) return;
  if (await _tracked(projectRoot, path)) return;
  final next = (await _read(projectRoot, path)).record(command, dir, took, DateTime.now());
  await File(path).parent.create(recursive: true);
  if (notesLinkProblem(projectRoot, tmp.path) != null) return;
  await tmp.writeAsString(jsonEncode(next.toJson()), flush: true);
  await tmp.rename(path);
  if (_excluded.add(projectRoot)) await excludeFromGit(projectRoot, const ['/$runtimeProfilesPath']);
}

/// [projectRoot]'s profiles; none when the file is a link, tracked by git (it came with the repository, so it
/// is someone else's text), or malformed.
Future<RuntimeProfiles> _read(String projectRoot, String path) async {
  try {
    final file = File(path);
    if (!file.existsSync() || notesLinkProblem(projectRoot, path) != null) return const RuntimeProfiles();
    if (await _tracked(projectRoot, path)) return const RuntimeProfiles();
    return RuntimeProfiles.fromJson(jsonDecode(await file.readAsString()));
  } on Object {
    return const RuntimeProfiles();
  }
}

/// Whether git tracks [path] in [root]'s repository.
Future<bool> _tracked(String root, String path) async {
  try {
    final r = await Process.run('git', ['ls-files', '--error-unmatch', path], workingDirectory: root);
    return r.exitCode == 0;
  } on Object {
    return false;
  }
}

/// The session's profile lines (`<sessionDir>/runtime-profiles`): rendered from [projectRoot]'s file the first time,
/// the same lines after, so a resumed conversation's prompt or briefing doesn't change (a lead switch keeps them too).
Future<List<String>> sessionRuntimeProfiles(String sessionDir, String projectRoot) async {
  final file = File('$sessionDir/runtime-profiles');
  try {
    return [
      for (final l in LineSplitter.split(await file.readAsString()))
        if (l.trim().isNotEmpty) l,
    ];
  } on FileSystemException {
    // Not written yet.
  }
  final lines = renderProfiles(await _read(projectRoot, '$projectRoot/$runtimeProfilesPath'));
  try {
    await Directory(sessionDir).create(recursive: true);
    await file.writeAsString(lines.map((l) => '$l\n').join());
  } on FileSystemException {
    // The briefing still gets them this time.
  }
  return lines;
}
