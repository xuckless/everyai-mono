import 'package:every_ai/features/local_models/data/server_probe.dart';
import 'package:every_ai/features/local_models/domain/fm.dart';
import 'package:every_ai/features/local_models/domain/local_server.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const _tags =
    '{"models":[{"name":"qwen3.5:9b","size":7086696448},{"name":"nomic-embed-text:latest","size":274302450}]}';
const _show =
    '{"capabilities":["completion","tools","vision","thinking"],"model_info":{"qwen35.context_length":262144}}';

void main() {
  group('identifying a server by its answers', () {
    test('Ollama on its port', () async {
      final http = FakeLocalHttp({
        'GET 127.0.0.1:11434/api/version': json('{"version":"0.21.0"}'),
        'GET 127.0.0.1:11434/api/tags': json(_tags),
      });
      final s = await identifyServer(http, 11434);
      expect(s?.kind, LocalServerKind.ollama);
      expect(s?.baseUrl, 'http://127.0.0.1:11434/v1');
    });

    test('our own dev backend on 8080 is skipped', () async {
      final http = FakeLocalHttp({
        'GET 127.0.0.1:8080/v1/ping': json('{"ok":true,"service":"everyai-backend-exp"}'),
        'GET 127.0.0.1:8080/v1/models': json('{"object":"list","data":[{"id":"anthropic/claude-haiku-5.5"}]}'),
      });
      expect(await identifyServer(http, 8080), isNull);
    });

    test('llama.cpp and MLX share 8080: /props tells them apart', () async {
      final llama = FakeLocalHttp({
        'GET 127.0.0.1:8080/props': json('{"default_generation_settings":{"n_ctx":32768},"total_slots":1}'),
      });
      expect((await identifyServer(llama, 8080))?.kind, LocalServerKind.llamacpp);
      final mlx = FakeLocalHttp({'GET 127.0.0.1:8080/v1/models': json('{"data":[{"id":"mlx-community/Qwen3"}]}')});
      expect((await identifyServer(mlx, 8080))?.kind, LocalServerKind.mlx);
    });

    test('LM Studio, vLLM, Jan, a plain server elsewhere, and Ollama moved to another port', () async {
      final http = FakeLocalHttp({
        'GET 127.0.0.1:1234/api/v0/models': json('{"data":[]}'),
        'GET 127.0.0.1:8000/v1/models': json(
          '{"data":[{"id":"Qwen/Qwen3-8B","owned_by":"vllm","max_model_len":32768}]}',
        ),
        'GET 127.0.0.1:1337/v1/models': json('{"data":[{"id":"llama3"}]}'),
        'GET 127.0.0.1:9000/v1/models': json('{"data":[{"id":"x"}]}'),
        'GET 127.0.0.1:1234/api/version': json('{"version":"0.21"}'),
      });
      expect((await identifyServer(http, 1234))?.kind, LocalServerKind.lmstudio);
      expect((await identifyServer(http, 8000))?.kind, LocalServerKind.vllm);
      expect((await identifyServer(http, 1337))?.kind, LocalServerKind.jan);
      final other = await identifyServer(http, 9000);
      expect(other?.kind, LocalServerKind.custom);
      expect(other?.id, 'openai:9000');
    });

    test('a scan keeps one server per kind, and nothing answering is nothing', () async {
      final http = FakeLocalHttp({
        'GET 127.0.0.1:11434/api/version': json('{"version":"0.21.0"}'),
        'GET 127.0.0.1:11434/api/tags': json(_tags),
      });
      final servers = await scanLocalPorts(http);
      expect(servers.map((s) => s.id), ['ollama']);
      expect(await scanLocalPorts(FakeLocalHttp()), isEmpty);
    });
  });

  group('listing models', () {
    test('Ollama: capabilities and context from /api/show; embedding models left out', () async {
      final http = FakeLocalHttp({
        'GET 127.0.0.1:11434/api/tags': json(_tags),
        'POST 127.0.0.1:11434/api/show#qwen3.5:9b': json(_show),
      });
      const server = LocalServer(
        id: 'ollama',
        kind: LocalServerKind.ollama,
        label: 'Ollama',
        baseUrl: 'http://127.0.0.1:11434/v1',
      );
      final models = await listServerModels(http, server);
      expect(models, [
        const LocalModel(
          name: 'qwen3.5:9b',
          serverId: 'ollama',
          contextTokens: 262144,
          tools: true,
          vision: true,
          reasoning: true,
          sizeBytes: 7086696448,
        ),
      ]);
      expect(models.single.id, 'local/qwen3.5:9b');
      expect(models.single.capsHeader, 'tools,vision,reasoning');
    });

    test('an Ollama model whose show fails gets the assumed context, marked as a guess', () {
      final m = ollamaModel('tiny', 'ollama', null);
      expect(m.contextTokens, assumedContext);
      expect(m.contextGuessed, isTrue);
      expect(m.tools, isFalse);
    });

    test('LM Studio: vlm is vision, tool_use is tools, embeddings are left out', () async {
      final http = FakeLocalHttp({
        'GET 127.0.0.1:1234/api/v0/models': json(
          '{"data":[{"id":"qwen3-vl","type":"vlm","max_context_length":32768,"capabilities":["tool_use"]},'
          '{"id":"text-embedding-nomic","type":"embeddings"}]}',
        ),
      });
      const server = LocalServer(
        id: 'lmstudio',
        kind: LocalServerKind.lmstudio,
        label: 'LM Studio',
        baseUrl: 'http://127.0.0.1:1234/v1',
      );
      final m = (await listServerModels(http, server)).single;
      expect((m.name, m.vision, m.tools, m.contextTokens), ('qwen3-vl', true, true, 32768));
    });

    test("Apple's fm: system with the assumed 4K window when it doesn't say", () async {
      final http = FakeLocalHttp({'GET 127.0.0.1:5555/v1/models': json('{"data":[{"id":"system"}]}')});
      const server = LocalServer(
        id: 'fm',
        kind: LocalServerKind.fm,
        label: 'Apple Intelligence',
        baseUrl: 'http://127.0.0.1:5555/v1',
      );
      final m = (await listServerModels(http, server)).single;
      expect((m.id, m.contextTokens, m.contextGuessed, m.tools), ('local/system', fmAssumedContext, true, true));
    });

    test('a manual server sends its key and reports a refusal plainly', () async {
      final http = FakeLocalHttp({'GET 10.0.0.5:8000/v1/models': json('{"error":"no"}', 401)});
      const server = LocalServer(
        id: 'custom:1',
        kind: LocalServerKind.custom,
        label: 'Box',
        baseUrl: 'http://10.0.0.5:8000/v1',
        apiKey: 'sk-1',
        manual: true,
      );
      expect((await testServer(http, server)).problem, 'The key was refused');
      expect((await testServer(FakeLocalHttp(), server)).problem, startsWith('Nothing answered'));
    });
  });

  test('base URLs are normalised to their /v1 root', () {
    expect(normaliseBaseUrl('localhost:8080'), 'http://localhost:8080/v1');
    expect(normaliseBaseUrl('http://10.0.0.5:8000/v1/'), 'http://10.0.0.5:8000/v1');
    expect(normaliseBaseUrl('https://box.lan/api/v1'), 'https://box.lan/api/v1');
    expect(normaliseBaseUrl('ftp://x'), isNull);
    expect(normaliseBaseUrl('  '), isNull);
  });

  group('fm', () {
    test('licence status, colours stripped', () {
      expect(
        parseFmLicence("\x1B[38;2;255;107;128mNot agreed. Run 'sudo fm license' to review and agree.\x1B[0m"),
        isFalse,
      );
      expect(parseFmLicence('You have already agreed to these terms.'), isTrue);
      expect(parseFmLicence('Agreed to license 1.0 on 2026-11-06'), isTrue);
      expect(parseFmLicence('something else'), isNull);
    });

    test('a Mac without Apple Intelligence', () {
      expect(parseFmUnsupported('This device does not support Apple Intelligence.'), isTrue);
      expect(parseFmUnsupported('system: available\npcc: available'), isFalse);
    });
  });
}
