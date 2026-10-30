import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/preferences.dart';
import '../code/code_providers.dart' show codeProjectsProvider;
import 'data/agent_store.dart';
import 'domain/agent_definition.dart';

export 'domain/agent_definition.dart';

/// The user's agent choices (Preferences `code.agent_library`).
final agentLibrarySettingsProvider = NotifierProvider<AgentLibrarySettingsNotifier, AgentLibrarySettings>(
  AgentLibrarySettingsNotifier.new,
);

final class AgentLibrarySettingsNotifier extends Notifier<AgentLibrarySettings> {
  static const key = 'code.agent_library';

  @override
  AgentLibrarySettings build() {
    final raw = ref.read(preferencesProvider)[key];
    if (raw == null) return const AgentLibrarySettings();
    try {
      return AgentLibrarySettings.fromJson(jsonDecode(raw));
    } on FormatException {
      return const AgentLibrarySettings();
    }
  }

  void _set(AgentLibrarySettings next) {
    state = next;
    ref.read(preferencesProvider)[key] = jsonEncode(next.toJson());
  }

  void setEnabled(AgentDefinition a, bool on) => _set(state.withEnabled(a.key, on));

  /// The model ('' for the orchestrator's) and effort ('' likewise) the user wants [name] on.
  void setPreferred(String name, {String? model, String? effort}) =>
      _set(state.withPreferred(name, model: model, effort: effort));

  /// Trusts [a] as it is on disk now; a later change turns it off again.
  void trust(AgentDefinition a) => _set(state.withTrust(a.key, a.digest).withEnabled(a.key, true));

  void untrust(AgentDefinition a) => _set(state.withTrust(a.key, null));

  void forget(AgentDefinition a) => _set(state.withTrust(a.key, null).withEnabled(a.key, true));
}

/// Built-in agents, the global folder, then each Code project's
/// `.everyai/agents`.
final agentLibraryProvider = AsyncNotifierProvider<AgentLibrary, List<AgentDefinition>>(AgentLibrary.new);

base class AgentLibrary extends AsyncNotifier<List<AgentDefinition>> {
  @override
  Future<List<AgentDefinition>> build() async {
    final projects = [for (final p in ref.watch(codeProjectsProvider)) (id: p.id, path: p.path)];
    return [...await _builtins(), ...await scanAgentFiles(await agentRoots(projects))];
  }

  Future<void> reload() async {
    state = await AsyncValue.guard(build);
  }

  /// Creates `<name>.md` in the global folder, or in [projectPath]'s
  /// `.everyai/agents`, from [text] (a template by default). What the user
  /// makes is theirs, so a new project agent is trusted at once.
  Future<AgentDefinition?> create(String name, {String? projectPath, String? text}) async {
    final dir = projectPath == null ? (await agentRoots(const [])).global : '$projectPath/$projectAgentsDir';
    if (dir == null) throw StateError('Agents need a file system.');
    final path = await createAgentFile(dir, name, text: text);
    return _afterWrite(path);
  }

  /// A copy of built-in [a] in the global folder, where it can be edited and
  /// takes the built-in's place.
  Future<AgentDefinition?> customize(AgentDefinition a) => create(a.name, text: a.text);

  /// Saves [text] over [a]'s file. A project agent the user edits here is
  /// trusted as saved.
  Future<AgentDefinition?> save(AgentDefinition a, String text) async {
    final path = a.path;
    if (path == null) throw StateError('Built-in agents are read-only; customize one to edit it.');
    await writeAgentFile(path, text);
    return _afterWrite(path);
  }

  Future<void> remove(AgentDefinition a) async {
    final path = a.path;
    if (path == null) return;
    await deleteAgentFile(path);
    ref.read(agentLibrarySettingsProvider.notifier).forget(a);
    await reload();
  }

  Future<AgentDefinition?> _afterWrite(String path) async {
    await reload();
    final added = (state.value ?? const []).where((a) => a.path == path).firstOrNull;
    if (added != null && added.source == AgentSource.project && added.usable) {
      ref.read(agentLibrarySettingsProvider.notifier).trust(added);
    }
    return added;
  }
}

/// No agents and no disk access, for tests and hosts without a file system.
base class NoAgentLibrary extends AgentLibrary {
  @override
  Future<List<AgentDefinition>> build() async => const [];
}

Future<List<AgentDefinition>> _builtins() async {
  try {
    return await loadBuiltinAgents();
  } on Object {
    // Without the bundled agents the user's own still work.
    return const [];
  }
}

/// The agents a session in [projectId] may start, read from disk now so a
/// project agent changed since it was trusted stays out.
Future<List<AgentDefinition>> codeAgentsFor(Ref ref, String? projectId) async {
  final projects = [
    for (final p in ref.read(codeProjectsProvider))
      if (p.id == projectId) (id: p.id, path: p.path),
  ];
  final all = [...await _builtins(), ...await scanAgentFiles(await agentRoots(projects))];
  return sessionAgents(all, ref.read(agentLibrarySettingsProvider), projectId);
}
