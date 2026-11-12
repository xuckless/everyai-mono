// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/features/local_models/local_model_bridge.dart';
import 'package:every_ai/features/models/domain/local_routes.dart';
import 'package:flutter_test/flutter_test.dart';

const _qwen = LocalRoute(baseUrl: 'http://127.0.0.1:11434/v1', name: 'qwen3.5:9b', contextTokens: 32768, tools: true);
const _apple = LocalRoute(baseUrl: 'http://127.0.0.1:40001/v1', name: 'system', contextTokens: 4096);

void main() {
  tearDown(() {
    LocalRoutes.current = const {};
    LocalRoutes.aux = null;
  });

  group('chatTurnHeaders', () {
    test('a credit turn gets nothing, so it stays on our server', () {
      LocalRoutes.aux = _apple;
      expect(chatTurnHeaders('anthropic/claude-haiku-5.5', const {}), isEmpty);
    });

    test('a local turn says where its model is and what runs the side jobs', () {
      LocalRoutes.current = {'local/qwen3.5:9b': _qwen};
      LocalRoutes.aux = _apple;
      final h = chatTurnHeaders('local/qwen3.5:9b', const {});
      expect(h['X-Local-Base-Url'], 'http://127.0.0.1:11434/v1');
      expect(h['X-Local-Caps'], 'tools');
      expect(h['X-Local-Context'], '32768');
      expect(h['X-Local-Aux-Model'], 'local/system');
    });

    test('an OpenRouter key runs the side jobs itself; an Anthropic key does not', () {
      LocalRoutes.aux = _apple;
      expect(
        chatTurnHeaders('openai/gpt-6.1', const {'X-Provider-Key-OpenRouter': 'k'}),
        isNot(contains('X-Local-Aux-Model')),
      );
      expect(
        chatTurnHeaders('anthropic/claude-haiku-5.5', const {'X-Provider-Key-Anthropic': 'k'}),
        containsPair('X-Local-Aux-Model', 'local/system'),
      );
    });
  });

  group('catalog', () {
    late AppDatabase db;
    setUp(() => db = AppDatabase(NativeDatabase.memory()));
    tearDown(() => db.close());
  });
}
