import '../../../core/config/billing_flag.dart';

import 'package:flutter/foundation.dart';

import '../../models/domain/model_catalog.dart';

/// How a provider wants its key.
enum ProviderAuth { bearer, anthropic }

/// `connected`: checked live end to end (stream, tool call, usage), offered
/// in the picker and the shop. `saved`: its key can be saved and checked,
/// but nothing runs on it yet ("Saved · not connected yet").
enum ProviderStatus { connected, saved }

/// Which models a provider's key runs.
@immutable
sealed class ProviderCovers {
  const ProviderCovers();
  const factory ProviderCovers.all() = _CoversAll;
  const factory ProviderCovers.vendors(List<String> slugs) = CoversVendors;
  const factory ProviderCovers.ownIds() = _CoversOwnIds;
}

final class _CoversAll extends ProviderCovers {
  const _CoversAll();
}

final class CoversVendors extends ProviderCovers {
  const CoversVendors(this.slugs);
  final List<String> slugs;
}

/// The host has its own model ids; it needs its own catalog source first.
final class _CoversOwnIds extends ProviderCovers {
  const _CoversOwnIds();
}

/// A provider whose API key the user can bring (BYOK). The table is
/// `backend-exp/src/providers.json`, copied here; `test/features/byok_table_test.dart` fails when they differ.
@immutable
final class ByokProvider {
  const ByokProvider({
    required this.id,
    required this.name,
    required this.header,
    required this.logo,
    required this.auth,
    required this.baseUrl,
    required this.checkUrl,
    required this.keysUrl,
    required this.keyHint,
    required this.blurb,
    required this.covers,
    required this.idMap,
    required this.status,
  });

  /// Also the secure-storage key suffix (`byok.<id>`) and the billing account id.
  final String id;
  final String name;

  /// The request header the bundled server reads the key from.
  final String header;

  /// A file under `assets/logos/` (`Logo.file`); empty for a monogram.
  final String logo;
  final ProviderAuth auth;
  final String baseUrl;

  /// A free, read-only call that answers 200 for a good key and refuses a bad
  /// one. Empty when the provider has none (its model list is public, so it
  /// would accept any key): such a key is saved unchecked.
  final String checkUrl;

  /// Where to make a key.
  final String keysUrl;

  /// What a key starts with, as a placeholder.
  final String keyHint;

  /// Which models the key runs.
  final String blurb;
  final ProviderCovers covers;
  final Map<String, String> idMap;
  final ProviderStatus status;

  bool get connected => status == ProviderStatus.connected;

  /// Whether this provider's key can run [model] (whatever its [status]).
  bool coversModel(ModelId model) => switch (covers) {
    _CoversAll() => true,
    CoversVendors(:final slugs) => slugs.contains(ModelProvider.ofModel(model).slug),
    _CoversOwnIds() => false,
  };

  /// Whether calls to [model] can run on this key now: it covers it and is connected.
  bool runs(ModelId model) => connected && coversModel(model);

  static ByokProvider? byId(String id) => byokProviders.where((p) => p.id == id).firstOrNull;
}

/// The providers the API keys page lists, in order (generated from `providers.json`).
const byokProviders = <ByokProvider>[
  ByokProvider(
    id: 'openrouter',
    name: 'OpenRouter',
    header: 'X-Provider-Key-OpenRouter',
    logo: 'openrouter-color',
    auth: ProviderAuth.bearer,
    baseUrl: 'https://openrouter.ai/api/v1',
    checkUrl: 'https://openrouter.ai/api/v1/key',
    keysUrl: 'https://openrouter.ai/settings/keys',
    keyHint: 'sk-or-v1-…',
    blurb: 'Every model in the shop, plus web search, follow-ups and images.',
    covers: ProviderCovers.all(),
    idMap: {},
    status: ProviderStatus.connected,
  ),
  ByokProvider(
    id: 'anthropic',
    name: 'Anthropic',
    header: 'X-Provider-Key-Anthropic',
    logo: 'claude-color',
    auth: ProviderAuth.anthropic,
    baseUrl: 'https://api.anthropic.com/v1',
    checkUrl: 'https://api.anthropic.com/v1/models?limit=1',
    keysUrl: 'https://console.anthropic.com/settings/keys',
    keyHint: 'sk-ant-…',
    blurb: 'Claude models, straight from Anthropic.',
    covers: ProviderCovers.vendors(['anthropic']),
    idMap: {},
    status: ProviderStatus.connected,
  ),
  ByokProvider(
    id: 'openai',
    name: 'OpenAI',
    header: 'X-Provider-Key-OpenAI',
    logo: 'openai',
    auth: ProviderAuth.bearer,
    baseUrl: 'https://api.openai.com/v1',
    checkUrl: 'https://api.openai.com/v1/models',
    keysUrl: 'https://platform.openai.com/api-keys',
    keyHint: 'sk-…',
    blurb: 'GPT models, straight from OpenAI.',
    covers: ProviderCovers.vendors(['openai']),
    idMap: {},
    status: ProviderStatus.saved,
  ),
  ByokProvider(
    id: 'google',
    name: 'Google AI Studio',
    header: 'X-Provider-Key-Google',
    logo: 'gemini-color',
    auth: ProviderAuth.bearer,
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
    checkUrl: 'https://generativelanguage.googleapis.com/v1beta/openai/models',
    keysUrl: 'https://aistudio.google.com/apikey',
    keyHint: 'AIza…',
    blurb: 'Gemini models, through AI Studio\'s OpenAI-compatible endpoint.',
    covers: ProviderCovers.vendors(['google']),
    idMap: {},
    status: ProviderStatus.saved,
  ),
  ByokProvider(
    id: 'xai',
    name: 'xAI',
    header: 'X-Provider-Key-XAI',
    logo: 'grok',
    auth: ProviderAuth.bearer,
    baseUrl: 'https://api.x.ai/v1',
    checkUrl: 'https://api.x.ai/v1/models',
    keysUrl: 'https://console.x.ai',
    keyHint: 'xai-…',
    blurb: 'Grok models, straight from xAI.',
    covers: ProviderCovers.vendors(['x-ai']),
    idMap: {},
    status: ProviderStatus.saved,
  ),
  ByokProvider(
    id: 'deepseek',
    name: 'DeepSeek',
    header: 'X-Provider-Key-DeepSeek',
    logo: 'deepseek-color',
    auth: ProviderAuth.bearer,
    baseUrl: 'https://api.deepseek.com/v1',
    checkUrl: 'https://api.deepseek.com/v1/models',
    keysUrl: 'https://platform.deepseek.com/api_keys',
    keyHint: 'sk-…',
    blurb: 'DeepSeek models, straight from DeepSeek.',
    covers: ProviderCovers.vendors(['deepseek']),
    idMap: {},
    status: ProviderStatus.saved,
  ),
  ByokProvider(
    id: 'mistral',
    name: 'Mistral',
    header: 'X-Provider-Key-Mistral',
    logo: 'mistral-color',
    auth: ProviderAuth.bearer,
    baseUrl: 'https://api.mistral.ai/v1',
    checkUrl: 'https://api.mistral.ai/v1/models',
    keysUrl: 'https://console.mistral.ai/api-keys',
    keyHint: '',
    blurb: 'Mistral models, straight from Mistral.',
    covers: ProviderCovers.vendors(['mistralai']),
    idMap: {},
    status: ProviderStatus.saved,
  ),
  ByokProvider(
    id: 'moonshot',
    name: 'Moonshot',
    header: 'X-Provider-Key-Moonshot',
    logo: 'kimi',
    auth: ProviderAuth.bearer,
    baseUrl: 'https://api.moonshot.ai/v1',
    checkUrl: 'https://api.moonshot.ai/v1/models',
    keysUrl: 'https://platform.moonshot.ai/console/api-keys',
    keyHint: 'sk-…',
    blurb: 'Kimi models, straight from Moonshot (global platform keys).',
    covers: ProviderCovers.vendors(['moonshotai']),
    idMap: {},
    status: ProviderStatus.saved,
  ),
  ByokProvider(
    id: 'zai',
    name: 'Z.ai',
    header: 'X-Provider-Key-ZAI',
    logo: 'zai',
    auth: ProviderAuth.bearer,
    baseUrl: 'https://api.z.ai/api/paas/v4',
    checkUrl: 'https://api.z.ai/api/paas/v4/models',
    keysUrl: 'https://z.ai/manage-apikey/apikey-list',
    keyHint: '',
    blurb: 'GLM models, straight from Z.ai (global keys, pay as you go).',
    covers: ProviderCovers.vendors(['z-ai']),
    idMap: {},
    status: ProviderStatus.saved,
  ),
  ByokProvider(
    id: 'minimax',
    name: 'MiniMax',
    header: 'X-Provider-Key-MiniMax',
    logo: 'minimax-color',
    auth: ProviderAuth.bearer,
    baseUrl: 'https://api.minimax.io/v1',
    checkUrl: 'https://api.minimax.io/v1/models',
    keysUrl: 'https://platform.minimax.io/user-center/basic-information/interface-key',
    keyHint: '',
    blurb: 'MiniMax models, straight from MiniMax.',
    covers: ProviderCovers.vendors(['minimax']),
    idMap: {},
    status: ProviderStatus.saved,
  ),
  ByokProvider(
    id: 'dashscope',
    name: 'Alibaba Model Studio',
    header: 'X-Provider-Key-DashScope',
    logo: 'qwen-color',
    auth: ProviderAuth.bearer,
    baseUrl: 'https://dashscope-intl.aliyuncs.com/compatible-mode/v1',
    checkUrl: 'https://dashscope-intl.aliyuncs.com/compatible-mode/v1/models',
    keysUrl: 'https://modelstudio.console.alibabacloud.com/',
    keyHint: 'sk-…',
    blurb: 'Qwen models, through DashScope (international, Singapore).',
    covers: ProviderCovers.vendors(['qwen']),
    idMap: {},
    status: ProviderStatus.saved,
  ),
  ByokProvider(
    id: 'cohere',
    name: 'Cohere',
    header: 'X-Provider-Key-Cohere',
    logo: 'cohere-color',
    auth: ProviderAuth.bearer,
    baseUrl: 'https://api.cohere.ai/compatibility/v1',
    checkUrl: 'https://api.cohere.ai/compatibility/v1/models',
    keysUrl: 'https://dashboard.cohere.com/api-keys',
    keyHint: '',
    blurb: 'Command models, through Cohere\'s compatibility API.',
    covers: ProviderCovers.vendors(['cohere']),
    idMap: {},
    status: ProviderStatus.saved,
  ),
  ByokProvider(
    id: 'perplexity',
    name: 'Perplexity',
    header: 'X-Provider-Key-Perplexity',
    logo: 'perplexity-color',
    auth: ProviderAuth.bearer,
    baseUrl: 'https://api.perplexity.ai',
    checkUrl: 'https://api.perplexity.ai/v1/models',
    keysUrl: 'https://www.perplexity.ai/settings/api',
    keyHint: 'pplx-…',
    blurb: 'Sonar models, straight from Perplexity.',
    covers: ProviderCovers.vendors(['perplexity']),
    idMap: {},
    status: ProviderStatus.saved,
  ),
  ByokProvider(
    id: 'groq',
    name: 'Groq',
    header: 'X-Provider-Key-Groq',
    logo: '',
    auth: ProviderAuth.bearer,
    baseUrl: 'https://api.groq.com/openai/v1',
    checkUrl: 'https://api.groq.com/openai/v1/models',
    keysUrl: 'https://console.groq.com/keys',
    keyHint: 'gsk_…',
    blurb: 'Open models on Groq\'s hardware.',
    covers: ProviderCovers.ownIds(),
    idMap: {},
    status: ProviderStatus.saved,
  ),
  ByokProvider(
    id: 'together',
    name: 'Together AI',
    header: 'X-Provider-Key-Together',
    logo: '',
    auth: ProviderAuth.bearer,
    baseUrl: 'https://api.together.xyz/v1',
    checkUrl: 'https://api.together.xyz/v1/models',
    keysUrl: 'https://api.together.ai/settings/api-keys',
    keyHint: '',
    blurb: 'Open models on Together.',
    covers: ProviderCovers.ownIds(),
    idMap: {},
    status: ProviderStatus.saved,
  ),
  ByokProvider(
    id: 'fireworks',
    name: 'Fireworks',
    header: 'X-Provider-Key-Fireworks',
    logo: 'fireworks-color',
    auth: ProviderAuth.bearer,
    baseUrl: 'https://api.fireworks.ai/inference/v1',
    checkUrl: 'https://api.fireworks.ai/inference/v1/models',
    keysUrl: 'https://fireworks.ai/account/api-keys',
    keyHint: 'fw_…',
    blurb: 'Open models on Fireworks.',
    covers: ProviderCovers.ownIds(),
    idMap: {},
    status: ProviderStatus.saved,
  ),
  ByokProvider(
    id: 'cerebras',
    name: 'Cerebras',
    header: 'X-Provider-Key-Cerebras',
    logo: '',
    auth: ProviderAuth.bearer,
    baseUrl: 'https://api.cerebras.ai/v1',
    checkUrl: 'https://api.cerebras.ai/v1/models',
    keysUrl: 'https://cloud.cerebras.ai',
    keyHint: 'csk-…',
    blurb: 'Open models on Cerebras.',
    covers: ProviderCovers.ownIds(),
    idMap: {},
    status: ProviderStatus.saved,
  ),
  ByokProvider(
    id: 'sambanova',
    name: 'SambaNova',
    header: 'X-Provider-Key-SambaNova',
    logo: '',
    auth: ProviderAuth.bearer,
    baseUrl: 'https://api.sambanova.ai/v1',
    checkUrl: '',
    keysUrl: 'https://cloud.sambanova.ai/apis',
    keyHint: '',
    blurb: 'Open models on SambaNova.',
    covers: ProviderCovers.ownIds(),
    idMap: {},
    status: ProviderStatus.saved,
  ),
  ByokProvider(
    id: 'github',
    name: 'GitHub Models',
    header: 'X-Provider-Key-GitHub',
    logo: 'githubcopilot',
    auth: ProviderAuth.bearer,
    baseUrl: 'https://models.github.ai/inference',
    checkUrl: 'https://api.github.com/user',
    keysUrl: 'https://github.com/settings/tokens',
    keyHint: 'github_pat_…',
    blurb: 'Models on GitHub, with a token that has models access.',
    covers: ProviderCovers.ownIds(),
    idMap: {},
    status: ProviderStatus.saved,
  ),
  ByokProvider(
    id: 'huggingface',
    name: 'Hugging Face',
    header: 'X-Provider-Key-HuggingFace',
    logo: 'huggingface-color',
    auth: ProviderAuth.bearer,
    baseUrl: 'https://router.huggingface.co/v1',
    checkUrl: 'https://huggingface.co/api/whoami-v2',
    keysUrl: 'https://huggingface.co/settings/tokens',
    keyHint: 'hf_…',
    blurb: 'Open models through Hugging Face\'s inference router.',
    covers: ProviderCovers.ownIds(),
    idMap: {},
    status: ProviderStatus.saved,
  ),
  ByokProvider(
    id: 'nvidia',
    name: 'NVIDIA NIM',
    header: 'X-Provider-Key-NVIDIA',
    logo: 'nvidia-color',
    auth: ProviderAuth.bearer,
    baseUrl: 'https://integrate.api.nvidia.com/v1',
    checkUrl: '',
    keysUrl: 'https://build.nvidia.com',
    keyHint: 'nvapi-…',
    blurb: 'Open models on NVIDIA\'s hosted NIM endpoints.',
    covers: ProviderCovers.ownIds(),
    idMap: {},
    status: ProviderStatus.saved,
  ),
];

/// Who pays for a model's calls: one of the user's keys, or (only with
/// [BillingFlag.enabled]) EveryAI credits.
@immutable
final class Biller {
  const Biller._(this.id, this._label, this.provider);

  /// No key of the user's covers the model. With billing on that means the
  /// user's plan and wallet; parked, the call has nothing to run on (the
  /// server answers `no_api_key` unless the model is local or free).
  static const everyai = Biller._('everyai', null, null);

  factory Biller.key(ByokProvider p) => Biller._(p.id, 'Your ${p.name} key', p);

  final String id;
  final String? _label;

  String get label => _label ?? (BillingFlag.enabled ? 'EveryAI credits' : 'No key yet');

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

  /// The accounts that can pay for [model]: EveryAI credits (billing on
  /// only), then each key that covers it.
  List<Biller> billersFor(ModelId model) => [
    if (BillingFlag.enabled) Biller.everyai,
    for (final p in byokProviders)
      if (keys.containsKey(p.id) && p.runs(model)) Biller.key(p),
  ];

  /// Who pays for [model]: the user's pick while it's still possible, else
  /// the most specific key that covers it (Anthropic's for Claude), else credits.
  Biller billerFor(ModelId model) {
    final options = billersFor(model);
    final picked = choices[model.value];
    if (options.isEmpty) return Biller.everyai;
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
