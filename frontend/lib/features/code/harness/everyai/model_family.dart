/// Model families the EveryAI harness tunes its tools and rules for.
enum ModelFamily {
  /// Anthropic's Claude: the default tools and rules.
  claude,

  /// OpenAI's GPT, o-series and Codex: `apply_patch` instead of edit/write.
  gpt,

  /// Google's Gemini.
  gemini,

  /// Open-weight models that need stricter rules: DeepSeek, Kimi, GLM, Qwen.
  open,

  /// Anything else: the defaults.
  other,
}

const _openVendors = {'deepseek', 'moonshotai', 'moonshot', 'z-ai', 'zhipuai', 'zai-org', 'thudm', 'qwen'};
const _openNames = ['deepseek', 'kimi', 'glm', 'qwen', 'qwq'];

/// The family of [modelId], an OpenRouter id (`openai/gpt-6.1`) or a bare or
/// LiteLLM-prefixed one (`openai/anthropic/claude-sonnet-5.5`, `gpt-5.4-mini`).
ModelFamily familyOf(String modelId) {
  final parts = modelId.trim().toLowerCase().split('/');
  // A ":variant" suffix (":thinking", ":free") says nothing about the family.
  final name = parts.last.split(':').first;
  final vendors = parts.sublist(0, parts.length - 1).toSet();
  if (vendors.contains('anthropic') || name.startsWith('claude')) return ModelFamily.claude;
  if (name.startsWith('gpt') || name.contains('codex') || RegExp(r'^o\d').hasMatch(name)) return ModelFamily.gpt;
  if (name.startsWith('gemini')) return ModelFamily.gemini;
  if (vendors.any(_openVendors.contains) || _openNames.any(name.startsWith)) return ModelFamily.open;
  return ModelFamily.other;
}
