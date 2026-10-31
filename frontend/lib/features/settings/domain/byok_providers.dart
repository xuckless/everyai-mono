import 'package:flutter/widgets.dart';

/// A provider whose API key the user can bring (BYOK).
@immutable
final class ByokProvider {
  const ByokProvider({
    required this.id,
    required this.name,
    required this.monogram,
    required this.color,
    this.keyHint = '',
  });

  /// Also the secure-storage key suffix (`byok.<id>`).
  final String id;
  final String name;
  final String monogram;
  final Color color;

  /// What a key usually starts with, as a placeholder.
  final String keyHint;
}

/// The providers the Add API keys page lists, in order.
const byokProviders = <ByokProvider>[
  ByokProvider(id: 'anthropic', name: 'Anthropic', monogram: 'A', color: Color(0xFFD97757), keyHint: 'sk-ant-…'),
  ByokProvider(id: 'openai', name: 'OpenAI', monogram: 'O', color: Color(0xFF10A37F), keyHint: 'sk-…'),
  ByokProvider(id: 'google', name: 'Google Gemini', monogram: 'G', color: Color(0xFF4285F4), keyHint: 'AIza…'),
  ByokProvider(id: 'openrouter', name: 'OpenRouter', monogram: 'OR', color: Color(0xFF6467F2), keyHint: 'sk-or-…'),
  ByokProvider(id: 'xai', name: 'xAI', monogram: 'x', color: Color(0xFF222222), keyHint: 'xai-…'),
  ByokProvider(id: 'deepseek', name: 'DeepSeek', monogram: 'D', color: Color(0xFF4D6BFE), keyHint: 'sk-…'),
  ByokProvider(id: 'mistral', name: 'Mistral', monogram: 'M', color: Color(0xFFFA520F)),
  ByokProvider(id: 'groq', name: 'Groq', monogram: 'Gq', color: Color(0xFFF55036), keyHint: 'gsk_…'),
  ByokProvider(id: 'together', name: 'Together', monogram: 'T', color: Color(0xFF0F6FFF)),
  ByokProvider(id: 'moonshot', name: 'Moonshot (Kimi)', monogram: 'K', color: Color(0xFF1C1C1C), keyHint: 'sk-…'),
  ByokProvider(id: 'zhipu', name: 'Zhipu (GLM)', monogram: 'Z', color: Color(0xFF3859FF)),
  ByokProvider(id: 'alibaba', name: 'Alibaba (Qwen)', monogram: 'Q', color: Color(0xFF615CED), keyHint: 'sk-…'),
];
