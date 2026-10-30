import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/preferences.dart';
import '../skills/skills_providers.dart' show SkillSettings, SkillSettingsNotifier, skillSettingsProvider;
import 'mcp_providers.dart';
import 'permissions_providers.dart';
import 'settings/code_settings.dart';
import 'ultra/ui/ultra_toggle.dart' show ultraTopBarSlot;

export 'settings/code_settings.dart';

/// The overarching system prompts and session budgets (Preferences
/// `code.settings`, see [StoredCodeSettings]).
final codeSettingsProvider = NotifierProvider<CodeSettings, StoredCodeSettings>(CodeSettings.new);

final class CodeSettings extends Notifier<StoredCodeSettings> {
  static const key = 'code.settings';

  @override
  StoredCodeSettings build() {
    final raw = ref.read(preferencesProvider)[key];
    if (raw == null) return const StoredCodeSettings();
    try {
      return StoredCodeSettings.fromJson(jsonDecode(raw));
    } on FormatException {
      return const StoredCodeSettings();
    }
  }

  void _set(StoredCodeSettings next) {
    state = next;
    ref.read(preferencesProvider)[key] = jsonEncode(next.toJson());
  }

  /// The prompt for [projectId] (null: every project).
  void setPrompt(String? projectId, String prompt) => _set(state.withPrompt(projectId, prompt));

  /// Compact EveryAI sessions at [percent] of the context window (0: off).
  void setAutoCompact(int percent) => _set(state.withAutoCompact(percent));

  /// Caps session [sessionId]'s spending at [usd] dollars (null: no cap).
  void setBudget(String sessionId, double? usd) => _set(state.withBudget(sessionId, usd));

  /// Saves a global or project [edit] into the stores it came from: the
  /// permission, MCP and skill stores keep their own Preferences keys and
  /// formats, so their screens and sessions read the change as usual. MCP
  /// approvals and skill trust carry over (see [keepApprovals]). The session
  /// layer is applied by the session itself.
  void applyLayer(SettingsScope scope, LayerEdit edit, {String? projectId}) {
    if (scope == SettingsScope.session) throw ArgumentError('The session applies its own layer.');
    final id = scope == SettingsScope.global ? null : projectId;
    if (scope == SettingsScope.project && id == null) throw StateError('No project to save into.');
    final prefs = ref.read(preferencesProvider);

    if (edit.systemPrompt case final p?) setPrompt(id, p);

    if (edit.permissions case final rules?) {
      final old = ref.read(codePermissionsProvider);
      final next = id == null
          ? StoredPermissions(global: rules, projects: old.projects)
          : StoredPermissions(global: old.global, projects: {...old.projects, id: rules});
      prefs[CodePermissions.key] = jsonEncode(next.toJson());
      ref.invalidate(codePermissionsProvider);
    }

    if (edit.mcpServers case final servers?) {
      final old = ref.read(codeMcpServersProvider);
      final next = old.withList(id, keepApprovals(old.listFor(id), servers));
      prefs[CodeMcpServers.key] = jsonEncode(next.toJson());
      ref.invalidate(codeMcpServersProvider);
    }

    if (edit.skillsDisabled case final disabled?) {
      final old = ref.read(skillSettingsProvider);
      prefs[SkillSettingsNotifier.key] = jsonEncode(SkillSettings(disabled: disabled, trusted: old.trusted).toJson());
      ref.invalidate(skillSettingsProvider);
    }
  }
}

/// Every store the layered settings read; [session] adds the
/// session layer. [watch] (in build methods) rebuilds the caller on changes.
CodeSettingsSources codeSettingsSources(WidgetRef ref, {SessionLayer? session, bool watch = false}) => watch
    ? CodeSettingsSources(
        settings: ref.watch(codeSettingsProvider),
        permissions: ref.watch(codePermissionsProvider),
        mcp: ref.watch(codeMcpServersProvider),
        skills: ref.watch(skillSettingsProvider),
        session: session,
      )
    : CodeSettingsSources(
        settings: ref.read(codeSettingsProvider),
        permissions: ref.read(codePermissionsProvider),
        mcp: ref.read(codeMcpServersProvider),
        skills: ref.read(skillSettingsProvider),
        session: session,
      );

/// Builds the Ultra toggle for a session's top bar; null hides the slot.
typedef CodeTopBarSlot = Widget Function(BuildContext context, String sessionId);

/// The Ultra toggle's place in the Code top bar (locked off the Max plan).
final codeUltraSlotProvider = Provider<CodeTopBarSlot?>((ref) => ultraTopBarSlot);
