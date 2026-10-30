import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../domain/agent_definition.dart';
import 'agent_store.dart' show AgentRoots;

Future<AgentRoots> roots(List<({String id, String path})> projects) async {
  String? global;
  try {
    global = '${(await getApplicationSupportDirectory()).path}/agents';
  } on Object {
    global = null;
  }
  return (global: global, projects: projects);
}

Future<List<AgentDefinition>> scan(AgentRoots roots) async => [
  if (roots.global case final dir?) ...await scanDir(dir, AgentSource.global),
  for (final p in roots.projects) ...await scanDir('${p.path}/$projectAgentsDir', AgentSource.project, projectId: p.id),
];

/// The agent files directly in [dir], sorted by file name.
Future<List<AgentDefinition>> scanDir(String dir, AgentSource source, {String? projectId}) async {
  final d = Directory(dir);
  if (!d.existsSync()) return const [];
  final out = <AgentDefinition>[];
  try {
    final children = await d.list(followLinks: false).toList();
    children.sort((a, b) => a.path.compareTo(b.path));
    for (final e in children) {
      final name = e.uri.pathSegments.last;
      if (!name.endsWith('.md') || name.startsWith('.')) continue;
      // A repository may not link files in from elsewhere on the disk.
      if (e is Link && source == AgentSource.project) continue;
      final f = File(e.path);
      try {
        if (!f.existsSync()) continue;
        if (await f.length() > maxAgentFileBytes) {
          out.add(
            AgentDefinition.parse(
              'x' * (maxAgentFileBytes + 1),
              fileName: name,
              source: source,
              path: f.path,
              projectId: projectId,
            ),
          );
          continue;
        }
        out.add(
          AgentDefinition.parse(
            await f.readAsString(),
            fileName: name,
            source: source,
            path: f.path,
            projectId: projectId,
          ),
        );
      } on FileSystemException {
        continue;
      } on FormatException {
        continue;
      }
    }
  } on FileSystemException {
    return out;
  }
  return out;
}

Future<String> create(String dir, String name, String text) async {
  if (!agentNamePattern.hasMatch(name)) {
    throw StateError('Use lowercase letters, digits, - and _ for the name (up to 48 characters).');
  }
  final file = File('$dir/$name.md');
  if (file.existsSync()) throw StateError('An agent named $name is already there.');
  await file.parent.create(recursive: true);
  await file.writeAsString(text);
  return file.path;
}

Future<void> write(String path, String text) => File(path).writeAsString(text);

Future<void> delete(String path) async {
  final f = File(path);
  if (f.existsSync()) await f.delete();
}
