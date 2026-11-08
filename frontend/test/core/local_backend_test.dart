// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';

import 'package:every_ai/core/local_backend/local_backend_io.dart';
import 'package:every_ai/core/net/api_error.dart';
import 'package:every_ai/features/chat/data/chat_transport.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Recorder implements ChatTransport {
  _Recorder(this.name);
  final String name;
  final sent = <ChatRequest>[];

  @override
  Stream<ChatEvent> send(ChatRequest request, {Future<void>? cancel}) async* {
    sent.add(request);
    yield TextDelta(name);
  }
}

final class _Results implements ToolResults {
  _Results(this.answers);
  final bool answers;
  final calls = <String>[];

  @override
  Future<bool> resolve(String callId, Object? result, {bool isError = false, List<String> images = const []}) async {
    calls.add(callId);
    return answers;
  }
}

ChatRequest _request(String model, {Map<String, String> keys = const {}}) => ChatRequest(
  model: ModelSpec(id: ModelId(model), provider: ModelProvider.anthropic, name: model),
  prompt: 'hi',
  providerKeys: keys,
);

void main() {
  group('findLocalBackend', () {
    test('prefers the override, then the bundle, then the dev build', () {
      final have = <String>{};
      String? find({Map<String, String> env = const {}}) =>
          findLocalBackend(env: env, exe: '/App/MacOS/EveryAI', cwd: '/src/frontend', exists: have.contains);
      expect(find(), isNull);
      have.add('/src/frontend/.local-backend/everyai-backend');
      expect(find(), '/src/frontend/.local-backend/everyai-backend');
      have.add('/App/MacOS/everyai-backend');
      expect(find(), '/App/MacOS/everyai-backend');
      have.add('/custom/bin');
      expect(find(env: {'EVERYAI_BACKEND_BIN': '/custom/bin'}), '/custom/bin');
    }, skip: Platform.isWindows);
  });

  group('SplitTransport', () {
    late _Recorder remote;
    late _Recorder local;
    setUp(() {
      remote = _Recorder('remote');
      local = _Recorder('local');
    });

    test('local models and own-key turns go to the bundled server, credits to ours', () async {
      final split = SplitTransport(remote: remote, local: () async => local, localProblem: () => null);
      await split.send(_request('local/qwen3:8b')).drain<void>();
      await split.send(_request('anthropic/claude-haiku-5.5', keys: {'X-Provider-Key-Anthropic': 'k'})).drain<void>();
      await split.send(_request('anthropic/claude-haiku-5.5')).drain<void>();
      expect(local.sent.map((r) => r.model.id.value), ['local/qwen3:8b', 'anthropic/claude-haiku-5.5']);
      expect(remote.sent.single.providerKeys, isEmpty);
    });

    test('without a bundled server: own keys fall back to ours, local models fail with the reason', () async {
      final split = SplitTransport(remote: remote, local: () async => null, localProblem: () => 'No server here.');
      await split.send(_request('openai/gpt-6.1', keys: {'X-Provider-Key-OpenRouter': 'k'})).drain<void>();
      expect(remote.sent, hasLength(1));
      expect(
        split.send(_request('local/llama')).drain<void>(),
        throwsA(isA<ProtocolError>().having((e) => e.message, 'message', 'No server here.')),
      );
    });
  });

  group('SplitToolResults', () {
    test('asks the bundled server first, then ours', () async {
      final local = _Results(false);
      final remote = _Results(true);
      final split = SplitToolResults(remote: remote, local: () async => local);
      expect(await split.resolve('c1', 'ok'), isTrue);
      expect(
        [local.calls, remote.calls],
        [
          ['c1'],
          ['c1'],
        ],
      );
      expect(await SplitToolResults(remote: remote, local: () async => null).resolve('c2', 'ok'), isTrue);
    });
  });

  test('IoLocalBackend starts a server, passes the token and stops it', () async {
    final dir = await Directory.systemTemp.createTemp('local_backend_test');
    addTearDown(() => dir.delete(recursive: true));
    // A stand-in for the real binary: answers /v1/ping and records its environment.
    final fake = File('${dir.path}/fake-backend')
      ..writeAsStringSync('''#!/usr/bin/env python3
import http.server, os, json
open(os.path.join(os.getcwd(), 'env.json'), 'w').write(json.dumps({k: os.environ.get(k) for k in ['LOCAL_MODE', 'LOCAL_TOKEN', 'HOST', 'OPENROUTER_API_KEY']}))
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'{"ok":true,"service":"everyai-backend-exp"}'
        self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', int(os.environ['PORT'])), H).serve_forever()
''');
    await Process.run('chmod', ['+x', fake.path]);
    final data = Directory('${dir.path}/data');
    final backend = IoLocalBackend(binary: fake.path, dataDir: data.path);
    final info = await backend.ensureStarted();
    expect(info, isNotNull, reason: backend.problem);
    expect(backend.running, isTrue);
    expect(identical(await backend.ensureStarted(), info), isTrue);
    final env = File('${data.path}/env.json').readAsStringSync();
    expect(env, contains('"LOCAL_MODE": "true"'));
    expect(env, contains('"LOCAL_TOKEN": "${info!.token}"'));
    expect(env, contains('"OPENROUTER_API_KEY": null'));
    await backend.stop();
    expect(backend.running, isFalse);
  }, skip: Platform.isWindows || !File('/usr/bin/env').existsSync());

  test('IoLocalBackend reports a missing binary', () async {
    final backend = IoLocalBackend(binary: null, dataDir: Directory.systemTemp.path);
    // No EVERYAI_BACKEND_BIN and no build next to the test runner.
    if (findLocalBackend() != null) return;
    expect(await backend.ensureStarted(), isNull);
    expect(backend.problem, contains("doesn't include"));
  });
}
