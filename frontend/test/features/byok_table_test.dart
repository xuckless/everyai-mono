import 'dart:convert';
import 'dart:io';

import 'package:every_ai/core/local_backend/local_backend.dart';
import 'package:every_ai/core/local_backend/local_gateway.dart';
import 'package:every_ai/core/net/api_client.dart';
import 'package:every_ai/features/code/harness/everyai/llm.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/settings/domain/byok_providers.dart';
import 'package:every_ai/features/settings/domain/key_check.dart';
import 'package:every_ai/features/settings/domain/provider_key_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test("the app's provider table is backend-exp/src/providers.json", () {
    final json = jsonDecode(File('../backend-exp/src/providers.json').readAsStringSync()) as Map<String, Object?>;
    final rows = (json['providers']! as List).cast<Map<String, Object?>>();
    expect(byokProviders.map((p) => p.id), rows.map((r) => r['id']), reason: 'same providers, same order');
    for (final (p, r) in [for (var i = 0; i < rows.length; i++) (byokProviders[i], rows[i])]) {
      final covers = switch (p.covers) {
        CoversVendors(:final slugs) => slugs,
        final c => c == const ProviderCovers.all() ? 'all' : 'own_ids',
      };
      expect(
        {
          'name': p.name,
          'header': p.header,
          'logo': p.logo,
          'auth': p.auth.name,
          'base_url': p.baseUrl,
          'check_url': p.checkUrl,
          'keys_url': p.keysUrl,
          'key_hint': p.keyHint,
          'blurb': p.blurb,
          'covers': covers,
          'id_map': p.idMap,
          'status': p.status.name,
        },
        {
          for (final k in [
            'name',
            'header',
            'logo',
            'auth',
            'base_url',
            'check_url',
            'keys_url',
            'key_hint',
            'blurb',
            'covers',
            'id_map',
            'status',
          ])
            k: r[k],
        },
        reason: p.id,
      );
      if (p.logo.isNotEmpty) expect(File('assets/logos/${p.logo}.svg').existsSync(), isTrue, reason: p.logo);
    }
  });

  test('a provider not connected yet is never offered, even with a key that works', () {
    final openai = ByokProvider.byId('openai')!;
    const model = ModelId('openai/gpt-6.1-sol');
    expect(openai.coversModel(model), isTrue);
    expect(openai.runs(model), isFalse);
    final billing = ModelBilling(keys: {'openai': 'sk-openai-key'});
    expect(billing.headersFor(model), isEmpty);
    expect(
      providerKeyState(
        openai,
        key: 'sk-openai-key',
        check: (tail: '-key', valid: true, at: DateTime(2026)),
        checking: false,
      ),
      isA<KeySavedNotConnected>(),
    );
    final anthropic = ByokProvider.byId('anthropic')!;
    expect(providerKeyState(anthropic, key: 'sk-ant-1234', check: null, checking: false), isA<KeySaved>());
    expect(
      providerKeyState(
        anthropic,
        key: 'sk-ant-1234',
        check: (tail: '1234', valid: false, at: DateTime(2026)),
        checking: false,
      ),
      isA<KeyRejected>(),
    );
    // A check of the key it replaced doesn't count.
    expect(
      providerKeyState(
        anthropic,
        key: 'sk-ant-5678',
        check: (tail: '1234', valid: false, at: DateTime(2026)),
        checking: false,
      ),
      isA<KeySaved>(),
    );
    expect(providerKeyState(anthropic, key: null, check: null, checking: false), isA<KeyUnset>());
  });

  test('no hosted call carries a provider key; only the bundled server takes one', () async {
    final seen = <Map<String, String>>[];
    MockClient recorder() => MockClient((req) async {
      seen.add(req.headers);
      return http.Response('{}', 200);
    });
    final hosted = ApiClient(baseUrl: Uri.parse('https://api.example/'), client: recorder());
    await expectLater(
      hosted.postJson('v1/chat/stream', const {}, headers: {'X-Provider-Key-OpenRouter': 'sk-or-v1-secret'}),
      throwsA(isA<AssertionError>()),
    );
    expect(seen.expand((h) => h.keys).where(ApiClient.isProviderKeyHeader), isEmpty);

    final local = ApiClient(baseUrl: Uri.parse('http://127.0.0.1:9/'), client: recorder(), acceptsProviderKeys: true);
    await local.postJson('v1/chat/stream', const {}, headers: {'X-Provider-Key-OpenRouter': 'sk-or-v1-secret'});
    expect(seen.last.keys.where(ApiClient.isProviderKeyHeader), hasLength(1));
  });

  group('Code on the user\'s own key', () {
    tearDown(() {
      ModelBilling.current = ModelBilling.empty;
      LocalGateway.resolve = null;
    });

    test('goes to the bundled server with its token, never with the hosted gateway key', () async {
      ModelBilling.current = const ModelBilling(keys: {'anthropic': 'sk-ant-user-key'});
      LocalGateway.resolve = () async => LocalBackendInfo(baseUrl: Uri.parse('http://127.0.0.1:4242/'), token: 'tok');
      final calls = <http.BaseRequest>[];
      final gw = GatewayClient(
        baseUrl: 'https://api.example/v1',
        apiKey: 'sk-eai-hosted',
        client: MockClient((req) async {
          calls.add(req);
          return http.Response('{"choices":[{"message":{"content":"ok"}}]}', 200);
        }),
      );
      await gw.raw({'model': 'anthropic/claude-haiku-5.5', 'messages': const []}, sessionTag: 's1');
      await gw.raw({'model': 'dots-studio/free', 'messages': const []}, sessionTag: 's1');
      expect(calls.first.url.toString(), 'http://127.0.0.1:4242/v1/chat/completions');
      expect(calls.first.headers['X-EveryAI-Local'], 'tok');
      expect(calls.first.headers['X-Provider-Key-Anthropic'], 'sk-ant-user-key');
      expect(calls.first.headers['Authorization'], isNull);
      expect(calls.last.url.host, 'api.example');
      expect(calls.last.headers.keys.where(ApiClient.isProviderKeyHeader), isEmpty);
    });

    test('fails when there is no bundled server instead of using ours', () async {
      ModelBilling.current = const ModelBilling(keys: {'anthropic': 'sk-ant-user-key'});
      LocalGateway.resolve = () async => null;
      var called = false;
      final gw = GatewayClient(
        baseUrl: 'https://api.example/v1',
        apiKey: 'sk-eai-hosted',
        client: MockClient((req) async {
          called = true;
          return http.Response('{}', 200);
        }),
      );
      await expectLater(
        gw.raw({'model': 'anthropic/claude-haiku-5.5', 'messages': const []}, sessionTag: 's1'),
        throwsA(isA<LlmError>().having((e) => e.message, 'message', LocalGateway.missing)),
      );
      expect(called, isFalse);
    });
  });
  group('key check', () {
    Future<KeyCheck> check(String id, int status, {List<Uri>? asked}) => checkProviderKey(
      ByokProvider.byId(id)!,
      'bad-key-0000',
      client: MockClient((req) async {
        asked?.add(req.url);
        return http.Response('{}', status);
      }),
    );

    test('a 400 is a rejected key (Google AI Studio and xAI answer a bad key so)', () async {
      expect((await check('google', 400)).valid, isFalse);
      expect((await check('xai', 400)).valid, isFalse);
      expect((await check('openai', 401)).valid, isFalse);
      expect((await check('openai', 200)).valid, isTrue);
      expect((await check('openai', 503)).valid, isNull);
    });

    test('no check goes to an endpoint that lists models to anyone', () async {
      for (final id in ['nvidia', 'sambanova']) {
        final asked = <Uri>[];
        final r = await check(id, 200, asked: asked);
        expect(r.valid, isNull, reason: id);
        expect(asked, isEmpty, reason: id);
      }
      for (final p in byokProviders) {
        expect(p.checkUrl, isNot(contains('models.github.ai/catalog')), reason: p.id);
        expect(p.checkUrl, isNot(contains('router.huggingface.co/v1/models')), reason: p.id);
      }
      expect(ByokProvider.byId('perplexity')!.checkUrl, 'https://api.perplexity.ai/v1/models');
    });
  });
}
