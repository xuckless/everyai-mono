import 'package:every_ai/features/chat/domain/chat_session.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final catalog = builtInCatalog;

  test('ids are unique and lookups are by id', () {
    expect(catalog.all.map((s) => s.id).toSet().length, catalog.all.length);
    expect(catalog[const ModelId('claude-haiku-5-5')]?.provider, ModelProvider.anthropic);
    expect(catalog[const ModelId('nope')], isNull);
  });

  test('every provider has a flagship and default model exists', () {
    for (final p in ModelProvider.values) {
      expect(catalog.flagship(p), isNotNull, reason: p.name);
    }
    expect(catalog.defaultModel.available, isTrue);
  });

  test('mentions resolve by label, short alias and exact id (case-insensitive)', () {
    expect(catalog.resolveMention('Claude'), catalog.flagship(ModelProvider.anthropic));
    expect(catalog.resolveMention('gpt'), catalog.flagship(ModelProvider.openai));
    expect(catalog.resolveMention('GEMINI-3.8-FLASH')?.id, const ModelId('gemini-3.8-flash'));
    expect(catalog.resolveMention('unknown'), isNull);
  });

  test('mention suggestions are prefix matches without duplicate models', () {
    final s = catalog.mentionSuggestions('cl').toList();
    expect(s, isNotEmpty);
    expect(s.every((e) => e.$1.startsWith('cl')), isTrue);
    expect(s.map((e) => e.$2.id).toSet().length, s.length);
  });

  group('parseMention', () {
    test('leading mention routes and is removed from the prompt', () {
      final r = parseMention('@claude explain monads', catalog);
      expect(r.model?.provider, ModelProvider.anthropic);
      expect(r.prompt, 'explain monads');
    });

    test('inline mention anywhere in the text', () {
      final r = parseMention('draw a cat @image please', catalog);
      expect(r.model?.provider, ModelProvider.stability);
      expect(r.prompt, 'draw a cat please');
    });

    test('emails and unknown handles stay untouched', () {
      final r = parseMention('mail me at a@b.com or @someone', catalog);
      expect(r.model, isNull);
      expect(r.prompt, 'mail me at a@b.com or @someone');
    });
  });

  test('titleFromPrompt uses the first line and truncates', () {
    expect(titleFromPrompt('  Hello\nworld'), 'Hello');
    final long = titleFromPrompt('x' * 100);
    expect(long.length, lessThanOrEqualTo(60));
    expect(long.endsWith('…'), isTrue);
  });
}
