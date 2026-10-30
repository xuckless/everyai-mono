import 'package:flutter/services.dart';

import '../domain/agent_definition.dart';
import 'agent_store_stub.dart' if (dart.library.io) 'agent_store_io.dart' as impl;

/// The folders agents are read from: app support `agents/` and each project's
/// `.everyai/agents`.
typedef AgentRoots = ({String? global, List<({String id, String path})> projects});

Future<AgentRoots> agentRoots(List<({String id, String path})> projects) => impl.roots(projects);

/// Every `*.md` under [roots], parsed (unusable ones carry their errors).
/// Links are skipped in project folders.
Future<List<AgentDefinition>> scanAgentFiles(AgentRoots roots) => impl.scan(roots);

/// Writes a new agent file `<dir>/<name>.md` with [text] (a template by
/// default) and returns its path. Throws [StateError] when the name is
/// invalid or taken.
Future<String> createAgentFile(String dir, String name, {String? text}) =>
    impl.create(dir, name, text ?? AgentDefinition.template(name));

/// Replaces [path]'s contents.
Future<void> writeAgentFile(String path, String text) => impl.write(path, text);

Future<void> deleteAgentFile(String path) => impl.delete(path);

const builtinAgentsAssetDir = 'assets/agents/';

/// The agents bundled with the app (`assets/agents/*.md`), sorted by name.
Future<List<AgentDefinition>> loadBuiltinAgents([AssetBundle? bundle]) async {
  final b = bundle ?? rootBundle;
  final manifest = await AssetManifest.loadFromAssetBundle(b);
  final out = <AgentDefinition>[];
  for (final asset in manifest.listAssets()) {
    final path = Uri.decodeFull(asset);
    if (!path.startsWith(builtinAgentsAssetDir) || !path.endsWith('.md')) continue;
    final file = path.substring(builtinAgentsAssetDir.length);
    if (file.contains('/')) continue;
    out.add(AgentDefinition.parse(await b.loadString(asset), fileName: file, source: AgentSource.builtin));
  }
  return out..sort((a, b) => a.name.compareTo(b.name));
}
