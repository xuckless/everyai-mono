import 'package:every_ai/features/local_models/data/server_probe.dart';
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

    test('llama.cpp and MLX share 8080: /props tells them apart', () async {
      final llama = FakeLocalHttp({
        'GET 127.0.0.1:8080/props': json('{"default_generation_settings":{"n_ctx":32768},"total_slots":1}'),
      });
      expect((await identifyServer(llama, 8080))?.kind, LocalServerKind.llamacpp);
      final mlx = FakeLocalHttp({'GET 127.0.0.1:8080/v1/models': json('{"data":[{"id":"mlx-community/Qwen3"}]}')});
      expect((await identifyServer(mlx, 8080))?.kind, LocalServerKind.mlx);
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

  group('fm', () {});
}
