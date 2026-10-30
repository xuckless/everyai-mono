import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'agent_settings.dart';
import 'settings.dart' show localSettingsPath, projectSettingsPath;

Future<AgentSettings> loadAgentSettings(String projectDir) async {
  return AgentSettings.layered([
    for (final path in [?await _userSettings(), '$projectDir/$projectSettingsPath', '$projectDir/$localSettingsPath'])
      ?await _read(path),
  ]);
}

/// App Support `settings.json`; null where there is no app (headless tools).
Future<String?> _userSettings() async {
  try {
    return '${(await getApplicationSupportDirectory()).path}/settings.json';
  } on Object {
    return null;
  }
}

Future<Map<String, Object?>?> _read(String path) async {
  final f = File(path);
  if (!f.existsSync()) return null;
  try {
    final json = jsonDecode(await f.readAsString());
    return json is Map<String, Object?> ? json : null;
  } on Object {
    return null;
  }
}

Future<CommitStyle> resolveCommitStyle(String projectDir, CommitStyle style) async {
  if (style != CommitStyle.auto) return style;
  try {
    final res = await Process.run('git', ['-C', projectDir, 'log', '-30', '--format=%s']);
    if (res.exitCode != 0) return CommitStyle.conventional;
    return detectCommitStyle(const LineSplitter().convert(res.stdout as String));
  } on Object {
    return CommitStyle.conventional;
  }
}

Future<void> excludeFromGit(String workingDir, List<String> patterns) async {
  final ProcessResult res;
  try {
    res = await Process.run('git', ['-C', workingDir, 'rev-parse', '--path-format=absolute', '--git-common-dir']);
  } on Object {
    return;
  }
  if (res.exitCode != 0) return;
  final exclude = File('${(res.stdout as String).trim()}/info/exclude');
  final lines = exclude.existsSync() ? await exclude.readAsLines() : <String>[];
  // Earlier versions excluded all of .everyai/, which hid the committed settings.
  final kept = [
    for (final l in lines)
      if (l.trim() != '.everyai/') l,
  ];
  final missing = [
    for (final p in patterns)
      if (!kept.any((l) => l.trim() == p)) p,
  ];
  if (missing.isEmpty && kept.length == lines.length) return;
  await exclude.parent.create(recursive: true);
  await exclude.writeAsString('${[...kept, ...missing].join('\n')}\n');
}
