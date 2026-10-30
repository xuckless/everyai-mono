import 'package:flutter/foundation.dart';

/// How agents write commit messages.
enum CommitStyle {
  /// Follow the repository's recent history (see [detectCommitStyle]).
  auto,

  /// `type(scope): subject`, e.g. `fix(auth): refresh tokens before expiry`.
  conventional,

  /// An imperative subject ("Add X", "Fix Y") and a body that says why.
  plain;

  static CommitStyle parse(Object? v) => values.where((s) => s.name == v).firstOrNull ?? auto;
}

/// A subagent role the agent may delegate to.
@immutable
final class AgentType {
  const AgentType({required this.name, required this.description, this.prompt = ''});

  final String name;
  final String description;

  /// Extra instructions for that subagent.
  final String prompt;

  Map<String, Object?> toJson() => {'description': description, if (prompt.isNotEmpty) 'prompt': prompt};
}

/// How Code agents should behave, from `settings.json` files. Layers merge
/// in order (user, then project `.everyai/settings.json`, then the
/// uncommitted `.everyai/settings.local.json`): later scalars win, rule lists
/// add up, agent types merge by name.
///
/// ```json
/// {
///   "instructions": ["Run `dart format -l 120` on changed files"],
///   "git": {"commitStyle": "auto", "attribution": false},
///   "agents": {"reviewer": {"description": "Reviews a diff for bugs", "prompt": "…"}},
///   "permissions": {"allow": [], "deny": []}
/// }
/// ```
@immutable
final class AgentSettings {
  const AgentSettings({
    this.instructions = const [],
    this.commitStyle = CommitStyle.auto,
    this.attribution = false,
    this.agents = const {},
    this.allow = const [],
    this.deny = const [],
  });

  static const defaults = AgentSettings();

  /// Project rules, added to the agent's system prompt.
  final List<String> instructions;
  final CommitStyle commitStyle;

  /// Whether commits and PRs may name the agent, the tool or its maker
  /// (Co-authored-by trailers, "Generated with …"). Off by default.
  final bool attribution;
  final Map<String, AgentType> agents;

  /// Command prefixes for the permission system (stored; not enforced yet).
  final List<String> allow;
  final List<String> deny;

  static AgentSettings fromJson(Map<String, Object?> json) {
    final git = json['git'] is Map<String, Object?> ? json['git']! as Map<String, Object?> : const <String, Object?>{};
    final perms = json['permissions'] is Map<String, Object?>
        ? json['permissions']! as Map<String, Object?>
        : const <String, Object?>{};
    final agents = json['agents'] is Map<String, Object?>
        ? json['agents']! as Map<String, Object?>
        : const <String, Object?>{};
    List<String> strings(Object? v) => switch (v) {
      final String s when s.trim().isNotEmpty => [s.trim()],
      final List<Object?> l => [
        for (final s in l)
          if (s is String && s.trim().isNotEmpty) s.trim(),
      ],
      _ => const [],
    };
    return AgentSettings(
      instructions: strings(json['instructions']),
      commitStyle: CommitStyle.parse(git['commitStyle']),
      attribution: git['attribution'] == true,
      agents: {
        for (final e in agents.entries)
          if (e.value case final Map<String, Object?> a)
            e.key: AgentType(
              name: e.key,
              description: a['description'] as String? ?? '',
              prompt: a['prompt'] as String? ?? '',
            ),
      },
      allow: strings(perms['allow']),
      deny: strings(perms['deny']),
    );
  }

  /// [over] layered on top of this. A layer that doesn't mention a scalar
  /// keeps the value below it, so [raw] tells which keys it set.
  AgentSettings merge(AgentSettings over, Map<String, Object?> raw) {
    final git = raw['git'] is Map<String, Object?> ? raw['git']! as Map<String, Object?> : const <String, Object?>{};
    return AgentSettings(
      instructions: [...instructions, ...over.instructions],
      commitStyle: git.containsKey('commitStyle') ? over.commitStyle : commitStyle,
      attribution: git.containsKey('attribution') ? over.attribution : attribution,
      agents: {...agents, ...over.agents},
      allow: [...allow, ...over.allow],
      deny: [...deny, ...over.deny],
    );
  }

  /// Merges the layers in order, skipping missing or unreadable ones.
  static AgentSettings layered(Iterable<Map<String, Object?>> layers) {
    var s = defaults;
    for (final raw in layers) {
      s = s.merge(fromJson(raw), raw);
    }
    return s;
  }
}

final _conventional = RegExp(r'^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([^)]*\))?!?: \S');

/// The style most of [subjects] (recent commit subjects, newest first)
/// follow. A repo without history gets conventional commits.
CommitStyle detectCommitStyle(List<String> subjects) {
  final real = [
    for (final s in subjects)
      if (!s.startsWith('Merge ') && s.trim().isNotEmpty) s,
  ];
  if (real.length < 3) return CommitStyle.conventional;
  final conventional = real.where(_conventional.hasMatch).length;
  return conventional * 2 >= real.length ? CommitStyle.conventional : CommitStyle.plain;
}

/// Whether [subject] follows the conventional format.
bool isConventionalSubject(String subject) => _conventional.hasMatch(subject);
