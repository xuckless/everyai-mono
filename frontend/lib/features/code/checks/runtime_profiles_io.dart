// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';
import 'dart:io';

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
  final next = (await _read(path)).record(command, dir, took, DateTime.now());
  await File(path).parent.create(recursive: true);
  final tmp = File('$path.$pid.tmp');
  await tmp.writeAsString(jsonEncode(next.toJson()), flush: true);
  await tmp.rename(path);
  if (_excluded.add(projectRoot)) await excludeFromGit(projectRoot, const ['/$runtimeProfilesPath']);
}

Future<RuntimeProfiles> _read(String path) async {
  try {
    return RuntimeProfiles.fromJson(jsonDecode(await File(path).readAsString()));
  } on Object {
    return const RuntimeProfiles();
  }
}

/// The session's profile lines (`<sessionDir>/runtime-profiles`): rendered from [projectRoot]'s file the first time,
/// the same lines after, so a resumed conversation's briefing doesn't change.
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
  final lines = renderProfiles(await _read('$projectRoot/$runtimeProfilesPath'));
  try {
    await Directory(sessionDir).create(recursive: true);
    await file.writeAsString(lines.map((l) => '$l\n').join());
  } on FileSystemException {
    // The briefing still gets them this time.
  }
  return lines;
}
