import 'package:flutter/foundation.dart';

import '../../models/domain/model_catalog.dart';

/// A provider whose API key the user can bring (BYOK).
///
/// Only providers whose whole path the backend has proven (streaming, tool
/// calls, prompt caching, usage) are listed: OpenRouter, which serves every
/// catalog model, and Anthropic, which serves `anthropic/*` through the
/// backend's native adapter.
@immutable
final class ByokProvider {
  const ByokProvider({
    required this.id,
    required this.name,
    required this.logo,
    required this.header,
    required this.keyHint,
    required this.blurb,
    required this.keysUrl,
  });

  /// Also the secure-storage key suffix (`byok.<id>`) and the billing account id.
  final String id;
  final String name;

  /// Logo asset.
  final String logo;

  /// The request header the backend reads the key from.
  final String header;

  /// What a key starts with, as a placeholder.
  final String keyHint;

  /// Which models the key runs.
  final String blurb;

  /// Where to make a key.
  final String keysUrl;

  /// Whether this provider's key can run [model].
  bool covers(ModelId model) => switch (id) {
    'openrouter' => true,
    'anthropic' => ModelProvider.ofModel(model).slug == 'anthropic',
    _ => false,
  };

  static ByokProvider? byId(String id) => byokProviders.where((p) => p.id == id).firstOrNull;
}

/// The providers the Add API keys page lists, in order.
const byokProviders = <ByokProvider>[
  ByokProvider(
    id: 'openrouter',
    name: 'OpenRouter',
    logo: 'assets/models/openrouter.png',
    header: 'X-Provider-Key-OpenRouter',
    keyHint: 'sk-or-v1-…',
    blurb: 'Every model in the shop, plus web search, follow-ups and images.',
    keysUrl: 'https://openrouter.ai/settings/keys',
  ),
  ByokProvider(
    id: 'anthropic',
    name: 'Anthropic',
    logo: 'assets/models/claude.webp',
    header: 'X-Provider-Key-Anthropic',
    keyHint: 'sk-ant-…',
    blurb: 'Claude models, straight from Anthropic.',
    keysUrl: 'https://console.anthropic.com/settings/keys',
  ),
];

/// Who pays for a model's calls: EveryAI credits or one of the user's keys.
@immutable
final class Biller {
  const Biller._(this.id, this.label, this.provider);

  /// The user's plan and wallet.
  static const everyai = Biller._('everyai', 'EveryAI credits', null);

  factory Biller.key(ByokProvider p) => Biller._(p.id, 'Your ${p.name} key', p);

  final String id;
  final String label;

  /// The key's provider; null for EveryAI credits.
  final ByokProvider? provider;

  bool get isOwnKey => provider != null;

  @override
  bool operator ==(Object other) => other is Biller && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// The user's keys and which account each model bills to. A plain snapshot
/// the request paths read synchronously (chat turns, the Code gateway).
@immutable
final class ModelBilling {
  const ModelBilling({this.keys = const {}, this.choices = const {}});

  static const empty = ModelBilling();

  /// The latest snapshot, for code outside Riverpod (the Code harness's
  /// gateway client). Set by `modelBillingProvider`.
  static ModelBilling current = empty;

  /// Provider id → the whole key.
  final Map<String, String> keys;

  /// Model id → biller id the user picked.
  final Map<String, String> choices;

  bool get hasKeys => keys.isNotEmpty;

  /// The accounts that can pay for [model]: EveryAI credits, then each key that covers it.
  List<Biller> billersFor(ModelId model) => [
    Biller.everyai,
    for (final p in byokProviders)
      if (keys.containsKey(p.id) && p.covers(model)) Biller.key(p),
  ];

  /// Who pays for [model]: the user's pick while it's still possible, else
  /// the most specific key that covers it (Anthropic's for Claude), else credits.
  Biller billerFor(ModelId model) {
    final options = billersFor(model);
    final picked = choices[model.value];
    if (picked != null) {
      final hit = options.where((b) => b.id == picked).firstOrNull;
      if (hit != null) return hit;
    }
    final keyed = options.where((b) => b.isOwnKey).toList();
    if (keyed.isEmpty) return Biller.everyai;
    return keyed.firstWhere((b) => b.provider!.id != 'openrouter', orElse: () => keyed.first);
  }

  /// The key header for [model]'s calls; empty when credits pay.
  ///
  /// Only the chosen key goes out, so the backend can't pick another one.
  /// An OpenRouter key also carries the side calls (search, follow-ups,
  /// titles) when it is the one chosen.
  Map<String, String> headersFor(ModelId model) {
    final p = billerFor(model).provider;
    if (p == null) return const {};
    return {p.header: keys[p.id]!};
  }

  /// Whether [model]'s calls run on one of the user's keys.
  bool ownKey(ModelId model) => billerFor(model).isOwnKey;
}
