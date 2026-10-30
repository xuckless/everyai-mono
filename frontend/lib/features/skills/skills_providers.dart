import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/preferences.dart';
import '../code/code_providers.dart' show codeProjectsProvider;
import 'data/skill_import.dart';
import 'data/skill_store.dart';
import 'domain/skill_catalog.dart';

export 'domain/skill_catalog.dart';

/// The user's skill choices (Preferences `code.skills`, see [SkillSettings]).
final skillSettingsProvider = NotifierProvider<SkillSettingsNotifier, SkillSettings>(SkillSettingsNotifier.new);

final class SkillSettingsNotifier extends Notifier<SkillSettings> {
  static const key = 'code.skills';

  @override
  SkillSettings build() {
    final raw = ref.read(preferencesProvider)[key];
    if (raw == null) return const SkillSettings();
    try {
      return SkillSettings.fromJson(jsonDecode(raw));
    } on FormatException {
      return const SkillSettings();
    }
  }

  void _set(SkillSettings next) {
    state = next;
    ref.read(preferencesProvider)[key] = jsonEncode(next.toJson());
  }

  void setEnabled(InstalledSkill s, bool on) => _set(state.withEnabled(s.key, on));

  /// Trusts [s] as it is on disk now; a later change turns it off again.
  void trust(InstalledSkill s) => _set(state.withTrust(s.key, s.digest).withEnabled(s.key, true));

  void untrust(InstalledSkill s) => _set(state.withTrust(s.key, null));

  void forget(InstalledSkill s) => _set(state.withTrust(s.key, null).withEnabled(s.key, true));
}

/// Every skill folder: the EveryAI library, `~/.agents/skills`, and each Code
/// project's `.agents/skills`.
final installedSkillsProvider = AsyncNotifierProvider<InstalledSkills, List<InstalledSkill>>(InstalledSkills.new);

final class InstalledSkills extends AsyncNotifier<List<InstalledSkill>> {
  @override
  Future<List<InstalledSkill>> build() async => scanSkills(await _roots());

  Future<SkillRoots> _roots() =>
      skillRoots([for (final p in ref.watch(codeProjectsProvider)) (id: p.id, path: p.path)]);

  Future<void> reload() async {
    state = await AsyncValue.guard(build);
  }

  /// Copies [c] into the library, or into [projectPath]'s `.agents/skills`.
  /// What the user imports is theirs, so a project import is trusted at once.
  Future<InstalledSkill?> import(ImportCandidate c, {String? projectId, String? projectPath}) async {
    final roots = await skillRoots(const []);
    final dest = projectPath == null ? roots.library : '$projectPath/$projectSkillsDir';
    if (dest == null) throw StateError('Skills need a file system.');
    final dir = await installSkill(c, dest);
    await reload();
    final added = (state.value ?? const []).where((s) => s.dir == dir).firstOrNull;
    if (added != null && added.source == SkillSource.project) ref.read(skillSettingsProvider.notifier).trust(added);
    return added;
  }

  Future<void> remove(InstalledSkill s) async {
    await deleteSkill(s);
    ref.read(skillSettingsProvider.notifier).forget(s);
    await reload();
  }
}

/// The `agent_context.skills` for a new session in [projectId], read from
/// disk now so a project skill changed since it was trusted stays out.
Future<List<Map<String, Object?>>> codeSkillsFor(Ref ref, String? projectId) async {
  final projects = [
    for (final p in ref.read(codeProjectsProvider))
      if (p.id == projectId) (id: p.id, path: p.path),
  ];
  final all = await scanSkills(await skillRoots(projects));
  return [for (final s in sessionSkills(all, ref.read(skillSettingsProvider), projectId)) openHandsSkill(s)];
}
