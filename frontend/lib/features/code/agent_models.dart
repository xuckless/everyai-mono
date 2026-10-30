import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/preferences.dart';
import '../../core/providers.dart';

/// A tier of agent models (backend `agents.zig`).
@immutable
final class AgentTier {
  const AgentTier(this.id, this.name, this.blurb);
  final String id;
  final String name;
  final String blurb;
}

/// A model at a reasoning effort, placed in a tier.
@immutable
final class AgentChoice {
  const AgentChoice({
    required this.model,
    required this.effort,
    required this.tier,
    required this.label,
    this.blurb = '',
    this.subagents = false,
    this.verified = false,
    this.candidate = false,
    this.evidence = '',
  });

  final String model;
  final String effort;
  final String tier;

  /// "Opus 5.5 · medium".
  final String label;
  final String blurb;
  final bool subagents;
  final bool verified;
  final bool candidate;
  final String evidence;

  String get key => '$model@$effort';

  static AgentChoice? fromJson(Object? json) => switch (json) {
    {'model': final String model, 'effort': final String effort, 'tier': final String tier} => AgentChoice(
      model: model,
      effort: effort,
      tier: tier,
      label: (json as Map<String, Object?>)['label'] as String? ?? '$model · $effort',
      blurb: json['blurb'] as String? ?? '',
      subagents: json['subagents'] == true,
      verified: json['verified'] == true,
      candidate: json['candidate'] == true,
      evidence: json['evidence'] as String? ?? '',
    ),
    _ => null,
  };
}

@immutable
final class AgentCatalog {
  const AgentCatalog({required this.tiers, required this.models, required this.fallback});

  final List<AgentTier> tiers;
  final List<AgentChoice> models;

  /// The backend's default (an Everyday model).
  final AgentChoice fallback;

  /// Used until the backend answers the first time.
  static const builtIn = AgentCatalog(
    tiers: [AgentTier('everyday', 'Everyday', 'Well-scoped features and bug fixes across a few files.')],
    models: [_opus],
    fallback: _opus,
  );
  static const _opus = AgentChoice(
    model: 'anthropic/claude-opus-5.5',
    effort: 'medium',
    tier: 'everyday',
    label: 'Opus 5.5 · medium',
    verified: true,
  );

  static AgentCatalog? fromJson(Map<String, Object?> json) {
    final models = [for (final m in (json['models'] as List<Object?>? ?? const [])) ?AgentChoice.fromJson(m)];
    final fallback = AgentChoice.fromJson(json['default']) ?? models.firstOrNull;
    if (fallback == null) return null;
    return AgentCatalog(
      tiers: [
        for (final t in (json['tiers'] as List<Object?>? ?? const []))
          if (t case {'id': final String id, 'name': final String name})
            AgentTier(id, name, (t as Map<String, Object?>)['blurb'] as String? ?? ''),
      ],
      models: models,
      fallback: fallback,
    );
  }

  AgentChoice? byKey(String? key) => models.where((m) => m.key == key).firstOrNull;
}

const _catalogKey = 'code.agents';
const _choiceKey = 'code.agent';

/// The curated agent models: the last copy right away, refreshed from
/// `GET /v1/agents` once per launch.
final agentCatalogProvider = NotifierProvider<AgentCatalogNotifier, AgentCatalog>(AgentCatalogNotifier.new);

final class AgentCatalogNotifier extends Notifier<AgentCatalog> {
  @override
  AgentCatalog build() {
    final prefs = ref.read(preferencesProvider);
    Future.microtask(_refresh);
    return _decode(prefs[_catalogKey]) ?? AgentCatalog.builtIn;
  }

  static AgentCatalog? _decode(String? raw) {
    if (raw == null) return null;
    try {
      return AgentCatalog.fromJson(jsonDecode(raw) as Map<String, Object?>);
    } on Object {
      return null;
    }
  }

  Future<void> _refresh() async {
    try {
      final json = await ref.read(apiClientProvider).getJson('v1/agents');
      final next = AgentCatalog.fromJson(json);
      if (next == null || !ref.mounted) return;
      ref.read(preferencesProvider)[_catalogKey] = jsonEncode(json);
      state = next;
    } on Object {
      // Offline: keep the cached list.
    }
  }
}

/// The agent new Code sessions use (kept apart from Chat's default model).
final codeAgentProvider = NotifierProvider<CodeAgent, AgentChoice>(CodeAgent.new);

final class CodeAgent extends Notifier<AgentChoice> {
  @override
  AgentChoice build() {
    final catalog = ref.watch(agentCatalogProvider);
    return catalog.byKey(ref.read(preferencesProvider)[_choiceKey]) ?? catalog.fallback;
  }

  void choose(AgentChoice choice) {
    ref.read(preferencesProvider)[_choiceKey] = choice.key;
    state = choice;
  }
}
