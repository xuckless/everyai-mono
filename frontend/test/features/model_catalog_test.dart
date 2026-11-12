import 'package:every_ai/features/chat/domain/chat_session.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final catalog = builtInCatalog;

  /// Shaped like `GET /v1/models` entries.
  ModelCatalog([
    for (final json in [
      {
        'id': 'anthropic/claude-haiku-5.5',
        'name': 'Claude Haiku 5.5',
        'blurb': 'Fast.',
        'context_length': 1000000,
        'input_modalities': ['text', 'image'],
        'output_modalities': ['text'],
        'prompt_per_mtok': 0.115,
        'completion_per_mtok': 0.575,
        'free': false,
        'tools': true,
        'reasoning': true,
        'default': true,
        'created': 1790000000,
      },
      {
        'id': 'google/gemini-3.1-flash-image',
        'name': 'Gemini 3.1 Flash Image',
        'output_modalities': ['image', 'text'],
        'prompt_per_mtok': 0.3,
        'completion_per_mtok': 2.5,
        'created': 1780000000,
      },
      {
        'id': '~openai/gpt-latest',
        'name': 'GPT Latest',
        'prompt_per_mtok': 2.3,
        'completion_per_mtok': 11.5,
        'created': 1791000000,
      },
      {'id': 'qwen/qwen4-32b:free', 'name': 'Qwen4 32B (free)', 'free': true, 'created': 1785000000},
    ])
      ModelSpec.fromJson(json)!,
  ], defaultModel: defaultModelId);

  test('mentions resolve by label, name part, short alias and id (case-insensitive)', () {
    expect(catalog.resolveMention('Claude'), catalog.flagship(ModelProvider.anthropic));
    expect(catalog.resolveMention('gpt'), catalog.flagship(ModelProvider.openai));
    expect(catalog.resolveMention('CLAUDE-OPUS-5.5')?.id, const ModelId('anthropic/claude-opus-5.5'));
    expect(catalog.resolveMention('openai/gpt-6.1-sol')?.id, const ModelId('openai/gpt-6.1-sol'));
    expect(catalog.resolveMention('unknown'), isNull);
  });

  group('parseMention', () {
    test('leading mention routes and is removed from the prompt', () {
      final r = parseMention('@claude explain monads', catalog);
      expect(r.model?.provider, ModelProvider.anthropic);
      expect(r.prompt, 'explain monads');
    });
  });
}
