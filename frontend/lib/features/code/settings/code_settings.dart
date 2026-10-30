import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../skills/domain/skill_catalog.dart' show SkillSettings;
import '../domain/agent_mode.dart';
import '../domain/mcp_servers.dart';
import '../domain/permissions.dart';
import '../permissions_providers.dart' show StoredPermissions;

/// Where a Code setting lives. Later layers win: global, then the project,
/// then the session.
enum SettingsScope {
  global('Global', 'Every project'),
  project('Project', 'This project'),
  session('Session', 'This session only');

  const SettingsScope(this.label, this.blurb);
  final String label;
  final String blurb;

  static SettingsScope parse(Object? v) => values.where((s) => s.name == v).firstOrNull ?? global;
}

/// The settings the app keeps that no other store holds (Preferences
/// `code.settings`): the overarching system prompts and per-session
/// budgets.
///
/// ```json
/// {"global": {"systemPrompt": "Answer in British English."},
///  "projects": {"<project id>": {"systemPrompt": "Use pnpm, never npm."}},
///  "sessions": {"<session id>": {"budgetUsd": 5}}}
/// ```
@immutable
final class StoredCodeSettings {
  const StoredCodeSettings({this.globalPrompt = '', this.projectPrompts = const {}, this.budgets = const {}});

  final String globalPrompt;
  final Map<String, String> projectPrompts;

  /// Session id → spending cap in dollars.
  final Map<String, double> budgets;

  String promptFor(String? projectId) => projectId == null ? globalPrompt : projectPrompts[projectId] ?? '';

  StoredCodeSettings withPrompt(String? projectId, String prompt) {
    final p = prompt.trim();
    if (projectId == null) return StoredCodeSettings(globalPrompt: p, projectPrompts: projectPrompts, budgets: budgets);
    final next = {...projectPrompts}..remove(projectId);
    if (p.isNotEmpty) next[projectId] = p;
    return StoredCodeSettings(globalPrompt: globalPrompt, projectPrompts: next, budgets: budgets);
  }

  StoredCodeSettings withBudget(String sessionId, double? usd) {
    final next = {...budgets}..remove(sessionId);
    if (usd != null && usd > 0) next[sessionId] = usd;
    return StoredCodeSettings(globalPrompt: globalPrompt, projectPrompts: projectPrompts, budgets: next);
  }

  factory StoredCodeSettings.fromJson(Object? json) {
    if (json is! Map<String, Object?>) return const StoredCodeSettings();
    String prompt(Object? v) =>
        v is Map<String, Object?> && v['systemPrompt'] is String ? v['systemPrompt']! as String : '';
    final projects = json['projects'];
    final sessions = json['sessions'];
    return StoredCodeSettings(
      globalPrompt: prompt(json['global']),
      projectPrompts: {
        if (projects is Map<String, Object?>)
          for (final e in projects.entries)
            if (prompt(e.value) case final p when p.isNotEmpty) e.key: p,
      },
      budgets: {
        if (sessions is Map<String, Object?>)
          for (final e in sessions.entries)
            if (e.value case {'budgetUsd': final num usd} when usd > 0) e.key: usd.toDouble(),
      },
    );
  }

  Map<String, Object?> toJson() => {
    'global': {if (globalPrompt.isNotEmpty) 'systemPrompt': globalPrompt},
    'projects': {
      for (final e in projectPrompts.entries) e.key: {'systemPrompt': e.value},
    },
    'sessions': {
      for (final e in budgets.entries) e.key: {'budgetUsd': e.value},
    },
  };
}

/// What a session's settings layer holds. Model, effort and mode stay in the
/// session itself; the budget in [StoredCodeSettings].
typedef SessionLayer = ({String model, String effort, AgentMode mode, double? budgetUsd});

/// Everything the layered settings read from, as it is now.
@immutable
final class CodeSettingsSources {
  const CodeSettingsSources({
    this.settings = const StoredCodeSettings(),
    this.permissions = const StoredPermissions(),
    this.mcp = const StoredMcpServers(),
    this.skills = const SkillSettings(),
    this.session,
  });

  final StoredCodeSettings settings;
  final StoredPermissions permissions;
  final StoredMcpServers mcp;
  final SkillSettings skills;
  final SessionLayer? session;
}

/// One layer as the raw JSON editor shows it.
///
/// - global: `systemPrompt`, `permissions {allow, deny}`, `mcpServers [...]`,
///   `skills {disabled: [skill keys]}`
/// - project: `systemPrompt`, `permissions`, `mcpServers`
/// - session: `model`, `effort`, `mode`, `budgetUsd`
///
/// MCP approvals and skill trust are left out: they are given in their own
/// screens, after the user has seen what they approve.
Map<String, Object?> layerJson(SettingsScope scope, CodeSettingsSources s, {String? projectId}) {
  List<Object?> servers(String? id) => [
    for (final m in s.mcp.listFor(id)) {...m.toJson()}..remove('approved'),
  ];
  return switch (scope) {
    SettingsScope.global => {
      'systemPrompt': s.settings.globalPrompt,
      'permissions': s.permissions.global.toJson(),
      'mcpServers': servers(null),
      'skills': {
        'disabled': [...s.skills.disabled]..sort(),
      },
    },
    SettingsScope.project => {
      'systemPrompt': s.settings.promptFor(projectId),
      'permissions': (s.permissions.projects[projectId] ?? PermissionRules.none).toJson(),
      'mcpServers': servers(projectId),
    },
    SettingsScope.session => {
      if (s.session case final session?) ...{
        'model': session.model,
        'effort': session.effort,
        'mode': session.mode.name,
        'budgetUsd': session.budgetUsd,
      },
    },
  };
}

/// The settings a session in [projectId] runs with, every layer merged:
/// prompts join (global first), permission rules add up, a project MCP server
/// replaces a global one of the same name, the session's own values last.
Map<String, Object?> effectiveJson(CodeSettingsSources s, {String? projectId}) => {
  'systemPrompt': joinSystemPrompts(
    global: s.settings.globalPrompt,
    project: projectId == null ? '' : s.settings.promptFor(projectId),
  ),
  'permissions': s.permissions.rulesFor(projectId).toJson(),
  'mcpServers': [
    for (final m in s.mcp.serversFor(projectId)) {...m.toJson()..remove('approved'), 'active': m.active},
  ],
  'skills': {
    'disabled': [...s.skills.disabled]..sort(),
  },
  ...layerJson(SettingsScope.session, s),
};

/// [json] indented for the editor.
String prettyJson(Object? json) => const JsonEncoder.withIndent('  ').convert(json);

/// A layer read back from the editor.
@immutable
final class LayerEdit {
  const LayerEdit({
    this.systemPrompt,
    this.permissions,
    this.mcpServers,
    this.skillsDisabled,
    this.model,
    this.effort,
    this.mode,
    this.budgetUsd,
    this.clearBudget = false,
  });

  final String? systemPrompt;
  final PermissionRules? permissions;
  final List<McpServer>? mcpServers;
  final Set<String>? skillsDisabled;
  final String? model;
  final String? effort;
  final AgentMode? mode;
  final double? budgetUsd;

  /// `budgetUsd` was null or 0: no cap.
  final bool clearBudget;
}

/// Parses the editor's [text] for [scope]. Returns the edit, or the problems
/// that stop it from being saved (nothing is saved then). In the global and
/// project layers a key left out means empty; in the session layer it means
/// unchanged.
({LayerEdit? edit, List<String> errors}) parseLayer(SettingsScope scope, String text) {
  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException catch (e) {
    return (edit: null, errors: ['Not valid JSON: ${e.message}']);
  }
  if (json is! Map<String, Object?>) return (edit: null, errors: const ['The settings must be a JSON object.']);
  final errors = <String>[];
  final allowed = switch (scope) {
    SettingsScope.global => const {'systemPrompt', 'permissions', 'mcpServers', 'skills'},
    SettingsScope.project => const {'systemPrompt', 'permissions', 'mcpServers'},
    SettingsScope.session => const {'model', 'effort', 'mode', 'budgetUsd'},
  };
  for (final k in json.keys) {
    if (!allowed.contains(k)) errors.add('Unknown key "$k" in ${scope.label.toLowerCase()} settings.');
  }

  List<String>? strings(Object? v, String where) {
    if (v == null) return const [];
    if (v is! List<Object?> || v.any((s) => s is! String)) {
      errors.add('$where must be a list of strings.');
      return null;
    }
    return [
      for (final s in v.cast<String>())
        if (s.trim().isNotEmpty) s.trim(),
    ];
  }

  if (scope == SettingsScope.session) {
    final model = json['model'];
    final effort = json['effort'];
    final mode = json['mode'];
    final budget = json['budgetUsd'];
    if (model != null && (model is! String || model.trim().isEmpty)) errors.add('model must be a model id.');
    if (effort != null && effort is! String) errors.add('effort must be a string ("" for the default).');
    AgentMode? parsedMode;
    if (mode != null) {
      parsedMode = AgentMode.values.where((m) => m.name == mode).firstOrNull;
      if (parsedMode == null) {
        errors.add('mode must be one of ${AgentMode.values.map((m) => m.name).join(', ')}.');
      }
    }
    if (budget != null && (budget is! num || budget < 0)) errors.add('budgetUsd must be a positive number or null.');
    if (errors.isNotEmpty) return (edit: null, errors: errors);
    return (
      edit: LayerEdit(
        model: (model as String?)?.trim(),
        effort: effort as String?,
        mode: parsedMode,
        budgetUsd: budget is num && budget > 0 ? budget.toDouble() : null,
        clearBudget: json.containsKey('budgetUsd') && (budget == null || budget == 0),
      ),
      errors: const [],
    );
  }

  final prompt = json['systemPrompt'];
  if (prompt != null && prompt is! String) errors.add('systemPrompt must be a string.');

  PermissionRules? rules;
  switch (json['permissions']) {
    case null:
      rules = PermissionRules.none;
    case final Map<String, Object?> p:
      for (final k in p.keys) {
        if (k != 'allow' && k != 'deny') errors.add('Unknown key "$k" in permissions.');
      }
      final allow = strings(p['allow'], 'permissions.allow');
      final deny = strings(p['deny'], 'permissions.deny');
      if (allow != null && deny != null) rules = PermissionRules(allow: allow, deny: deny);
    default:
      errors.add('permissions must be an object with allow and deny lists.');
  }

  List<McpServer>? servers;
  switch (json['mcpServers']) {
    case null:
      servers = const [];
    case final List<Object?> list:
      servers = [];
      final names = <String>{};
      for (final (i, raw) in list.indexed) {
        final s = McpServer.fromJson(raw is Map<String, Object?> ? ({...raw}..remove('approved')) : raw);
        if (s == null) {
          errors.add('mcpServers[$i] needs at least a "name".');
        } else if (!names.add(s.name)) {
          errors.add('Two MCP servers are called "${s.name}".');
        } else if (s.problem case final p?) {
          errors.add('MCP server "${s.name}": $p');
        } else {
          servers.add(s);
        }
      }
    default:
      errors.add('mcpServers must be a list.');
  }

  Set<String>? disabled;
  if (scope == SettingsScope.global) {
    switch (json['skills']) {
      case null:
        disabled = const {};
      case final Map<String, Object?> sk:
        for (final k in sk.keys) {
          if (k != 'disabled') errors.add('Unknown key "$k" in skills.');
        }
        if (strings(sk['disabled'], 'skills.disabled') case final d?) disabled = {...d};
      default:
        errors.add('skills must be an object with a disabled list.');
    }
  }

  if (errors.isNotEmpty) return (edit: null, errors: errors);
  return (
    edit: LayerEdit(
      systemPrompt: (prompt as String? ?? '').trim(),
      permissions: rules,
      mcpServers: servers,
      skillsDisabled: disabled,
    ),
    errors: const [],
  );
}

/// [next] with each server keeping the approval its namesake in [previous]
/// had. An approval covers one exact command, arguments and environment
/// (`McpServer.consentKey`), so a server whose command changed in the editor
/// still needs approving.
List<McpServer> keepApprovals(List<McpServer> previous, List<McpServer> next) => [
  for (final s in next)
    if (previous.where((p) => p.name == s.name).firstOrNull?.approved case final a?)
      s.copyWith(approved: () => a)
    else
      s,
];

/// The user's standing instructions (global, then for the project), as a
/// block for the end of the agent's system prompt; '' when there are none.
String joinSystemPrompts({required String global, required String project}) =>
    [global.trim(), project.trim()].where((p) => p.isNotEmpty).join('\n\n');

/// [suffix] with the user's system prompts appended. They go last and stay
/// fixed for the session, so the cached prompt prefix still holds.
String withSystemPrompts(String suffix, {required String global, required String project}) {
  final g = global.trim();
  final p = project.trim();
  if (g.isEmpty && p.isEmpty) return suffix;
  final out = StringBuffer(suffix)
    ..write('\n\n<USER_SYSTEM_PROMPT>\n')
    ..write('The user wrote these standing instructions in EveryAI settings. Follow them in every turn; ')
    ..write('a later message from the user overrides them where the two disagree.\n');
  if (g.isNotEmpty) out.write('\n$g\n');
  if (p.isNotEmpty) out.write('\nFor this project:\n$p\n');
  out.write('</USER_SYSTEM_PROMPT>');
  return out.toString();
}

/// How much of [budgetUsd] the session has spent ([chargedMicros] is in
/// millionths of a dollar); null without a budget.
double? budgetFill(int chargedMicros, double? budgetUsd) =>
    budgetUsd == null || budgetUsd <= 0 ? null : chargedMicros / (budgetUsd * 1e6);

/// Whether spending went from under [budgetUsd] to at or over it between
/// [beforeMicros] and [afterMicros]: the moment the session is stopped.
bool crossedBudget(int beforeMicros, int afterMicros, double? budgetUsd) {
  if (budgetUsd == null || budgetUsd <= 0) return false;
  final cap = budgetUsd * 1e6;
  return beforeMicros < cap && afterMicros >= cap;
}

/// The budget picks the top bar offers, in dollars.
const budgetPresets = [1.0, 2.0, 5.0, 10.0, 25.0];
