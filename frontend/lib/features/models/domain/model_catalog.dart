import 'package:flutter/foundation.dart';

/// Wire identifier of a model, exactly as the provider API expects it.
/// An extension type: zero runtime cost, but can't be confused with other strings.
extension type const ModelId(String value) implements Object {}

enum ModelProvider {
  openai('ChatGPT', 'OpenAI', 'chat/gpt', 'assets/models/chatgpt.webp'),
  anthropic('Claude', 'Anthropic', 'chat/claude', 'assets/models/claude.webp'),
  google('Gemini', 'Google', 'chat/gemini', 'assets/models/gemini.png'),
  xai('Grok', 'xAI', 'chat/xai', 'assets/models/xai.webp'),
  meta('Llama', 'Meta', 'chat/llama', 'assets/models/Llama.jpeg'),
  stability('Stability', 'Stability AI', 'chat/stability', 'assets/models/stabilityai.webp');

  const ModelProvider(this.label, this.company, this.endpoint, this.asset);

  /// Product name shown in the UI.
  final String label;
  final String company;

  /// Backend route for one-shot (non-streaming) requests.
  final String endpoint;
  final String asset;
}

enum Modality {
  text('Text'),
  image('Image');

  const Modality(this.label);
  final String label;
}

@immutable
final class ModelSpec {
  const ModelSpec({
    required this.id,
    required this.provider,
    required this.name,
    this.blurb = '',
    this.output = Modality.text,
    this.available = true,
    this.supportsStreaming = true,
  });

  final ModelId id;
  final ModelProvider provider;
  final String name;
  final String blurb;
  final Modality output;

  /// False when the backend has no working route yet (shown, but disabled).
  final bool available;
  final bool supportsStreaming;

  @override
  bool operator ==(Object other) => other is ModelSpec && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'ModelSpec(${id.value})';
}

/// Immutable, indexed model registry: O(1) lookup by id, by provider and by @mention alias.
final class ModelCatalog {
  ModelCatalog(Iterable<ModelSpec> specs, {required ModelId defaultModel})
    : _byId = Map.unmodifiable({for (final s in specs) s.id: s}),
      _byProvider = Map.unmodifiable(_groupByProvider(specs)),
      _aliases = Map.unmodifiable(_buildAliases(specs)),
      _default = defaultModel {
    assert(_byId.containsKey(defaultModel), 'Default model must be in the catalog');
  }

  final Map<ModelId, ModelSpec> _byId;
  final Map<ModelProvider, List<ModelSpec>> _byProvider;
  final Map<String, ModelSpec> _aliases;
  final ModelId _default;

  Iterable<ModelSpec> get all => _byId.values;
  ModelSpec get defaultModel => _byId[_default]!;
  ModelSpec? operator [](ModelId id) => _byId[id];

  List<ModelSpec> byProvider(ModelProvider p) => _byProvider[p] ?? const [];

  /// The provider's first listed model is its flagship.
  ModelSpec? flagship(ModelProvider p) => _byProvider[p]?.firstOrNull;

  /// Resolves an @mention token (without the @), case-insensitive:
  /// a model id (`claude-haiku-5-5`), a provider label (`claude`, `gemini`) or a short alias (`gpt`).
  ModelSpec? resolveMention(String token) => _aliases[token.toLowerCase()];

  /// Aliases starting with [prefix], for the @ autocomplete.
  Iterable<(String alias, ModelSpec spec)> mentionSuggestions(String prefix) {
    final p = prefix.toLowerCase();
    final seen = <ModelId>{};
    return _aliases.entries.where((e) => e.key.startsWith(p) && seen.add(e.value.id)).map((e) => (e.key, e.value));
  }

  static Map<ModelProvider, List<ModelSpec>> _groupByProvider(Iterable<ModelSpec> specs) {
    final out = <ModelProvider, List<ModelSpec>>{};
    for (final s in specs) {
      (out[s.provider] ??= []).add(s);
    }
    return {for (final e in out.entries) e.key: List.unmodifiable(e.value)};
  }

  static Map<String, ModelSpec> _buildAliases(Iterable<ModelSpec> specs) {
    final out = <String, ModelSpec>{};
    for (final s in specs) {
      out[s.id.value.toLowerCase()] = s;
      // Provider label and company map to that provider's flagship (first wins).
      out.putIfAbsent(s.provider.label.toLowerCase(), () => s);
      out.putIfAbsent(s.provider.name, () => s);
    }
    for (final (alias, provider) in const [
      ('gpt', ModelProvider.openai),
      ('chatgpt', ModelProvider.openai),
      ('image', ModelProvider.stability),
    ]) {
      final flagship = specs.where((s) => s.provider == provider).firstOrNull;
      if (flagship != null) out.putIfAbsent(alias, () => flagship);
    }
    return out;
  }
}

/// Built-in catalog. IDs checked against provider model-list APIs on 2026-10-29
/// (OpenAI, Gemini); Anthropic IDs from Anthropic's current lineup. The xAI ID is
/// unverified because the xAI account has no credits. Long term the backend should
/// serve this list.
final builtInCatalog = ModelCatalog(const [
  ModelSpec(
    id: ModelId('gpt-6.1-sol'),
    provider: ModelProvider.openai,
    name: 'GPT-6.1 Sol',
    blurb: 'Flagship reasoning',
  ),
  ModelSpec(id: ModelId('gpt-6.1-terra'), provider: ModelProvider.openai, name: 'GPT-6.1 Terra', blurb: 'Balanced'),
  ModelSpec(id: ModelId('gpt-5.5'), provider: ModelProvider.openai, name: 'GPT-5.5'),
  ModelSpec(id: ModelId('gpt-5.4-mini'), provider: ModelProvider.openai, name: 'GPT-5.4 mini', blurb: 'Fast and cheap'),
  ModelSpec(
    id: ModelId('claude-opus-5-5'),
    provider: ModelProvider.anthropic,
    name: 'Claude Opus 5.5',
    blurb: 'Most capable',
  ),
  ModelSpec(id: ModelId('claude-fable-5-1'), provider: ModelProvider.anthropic, name: 'Claude Fable 5.1'),
  ModelSpec(
    id: ModelId('claude-sonnet-5-5'),
    provider: ModelProvider.anthropic,
    name: 'Claude Sonnet 5.5',
    blurb: 'Balanced',
  ),
  ModelSpec(
    id: ModelId('claude-haiku-5-5'),
    provider: ModelProvider.anthropic,
    name: 'Claude Haiku 5.5',
    blurb: 'Fastest',
  ),
  ModelSpec(id: ModelId('gemini-4-argon'), provider: ModelProvider.google, name: 'Gemini 4 Argon', blurb: 'Flagship'),
  ModelSpec(id: ModelId('gemini-3.8-flash'), provider: ModelProvider.google, name: 'Gemini 3.8 Flash', blurb: 'Fast'),
  ModelSpec(
    id: ModelId('gemini-3.5-flash-lite'),
    provider: ModelProvider.google,
    name: 'Gemini 3.5 Flash-Lite',
    blurb: 'Cheapest',
  ),
  ModelSpec(id: ModelId('grok-4'), provider: ModelProvider.xai, name: 'Grok 4'),
  ModelSpec(id: ModelId('llama'), provider: ModelProvider.meta, name: 'Llama', blurb: 'Coming soon', available: false),
  ModelSpec(
    id: ModelId('stable-image-ultra'),
    provider: ModelProvider.stability,
    name: 'Stable Image Ultra',
    blurb: 'Text to image',
    output: Modality.image,
    supportsStreaming: false,
  ),
], defaultModel: const ModelId('gpt-5.4-mini'));
