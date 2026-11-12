// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';

import 'package:every_ai/core/local_backend/local_backend.dart';
import 'package:every_ai/core/local_backend/local_backend_io.dart';
import 'package:every_ai/core/process/supervisor.dart';
import 'package:every_ai/core/net/api_error.dart';
import 'package:every_ai/features/chat/data/chat_transport.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

/// A stand-in for the real binary: answers /v1/ping and records its environment; with [ignoreTerm] it shrugs off
/// SIGTERM (and the shutdown request), so only SIGKILL ends it.
File fakeBackend(Directory dir, {bool ignoreTerm = false}) {
  final f = File('${dir.path}/fake-backend')
    ..writeAsStringSync('''#!/usr/bin/env python3
import http.server, os, json, signal
${ignoreTerm ? 'signal.signal(signal.SIGTERM, signal.SIG_IGN)' : ''}
open(os.path.join(os.getcwd(), 'env.json'), 'w').write(json.dumps({k: os.environ.get(k) for k in ['LOCAL_MODE', 'LOCAL_TOKEN', 'HOST', 'OPENROUTER_API_KEY']}))
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'{"ok":true,"service":"everyai-backend-exp"}'
        self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', int(os.environ['PORT'])), H).serve_forever()
''');
  Process.runSync('chmod', ['+x', f.path]);
  return f;
}

bool _alive(int p) {
  final stat = '${Process.runSync('ps', ['-o', 'stat=', '-p', '$p']).stdout}'.trim();
  return stat.isNotEmpty && !stat.startsWith('Z');
}

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

    test('without a bundled server: own keys never go to ours; both fail with the reason', () async {
      final split = SplitTransport(remote: remote, local: () async => null, localProblem: () => 'No server here.');
      expect(
        split.send(_request('openai/gpt-6.1', keys: {'X-Provider-Key-OpenRouter': 'k'})).drain<void>(),
        throwsA(isA<ProtocolError>().having((e) => e.message, 'message', 'No server here.')),
      );
      expect(remote.sent, isEmpty);
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

  const fast = StopTimings(
    termGrace: Duration(milliseconds: 300),
    killWait: Duration(seconds: 2),
    poll: Duration(milliseconds: 25),
  );
  final skipNoPython = Platform.isWindows || !File('/usr/bin/env').existsSync();

  test('IoLocalBackend starts a server, passes the token and stops it (checked ended)', () async {
    final dir = await Directory.systemTemp.createTemp('local_backend_test');
    addTearDown(() => dir.delete(recursive: true));
    final sup = ProcessSupervisor.create(
      ledgerDir: '${dir.path}/ledger',
      hooks: const SupervisorHooks(timings: fast),
    );
    final data = Directory('${dir.path}/data');
    final backend = IoLocalBackend(binary: fakeBackend(dir).path, dataDir: data.path, supervisor: sup);
    final info = await backend.ensureStarted();
    expect(info, isNotNull, reason: backend.problem);
    expect(backend.running, isTrue);
    expect(identical(await backend.ensureStarted(), info), isTrue);
    final env = File('${data.path}/env.json').readAsStringSync();
    expect(env, contains('"LOCAL_MODE": "true"'));
    expect(env, contains('"LOCAL_TOKEN": "${info!.token}"'));
    expect(env, contains('"OPENROUTER_API_KEY": null'));
    final serverPid = sup.children.single.pid!;
    expect(await backend.stop(), isA<Ended>());
    expect(backend.running, isFalse);
    expect(backend.phase, isA<BackendIdle>());
    expect(_alive(serverPid), isFalse);
  }, skip: skipNoPython);

  test('a server that ignores SIGTERM is killed, and the phase ends Idle (never stuck in Stopping)', () async {
    final dir = await Directory.systemTemp.createTemp('local_backend_test');
    addTearDown(() => dir.delete(recursive: true));
    final sup = ProcessSupervisor.create(
      ledgerDir: '${dir.path}/ledger',
      hooks: const SupervisorHooks(timings: fast),
    );
    final backend = IoLocalBackend(
      binary: fakeBackend(dir, ignoreTerm: true).path,
      dataDir: '${dir.path}/data',
      supervisor: sup,
    );
    expect(await backend.ensureStarted(), isNotNull, reason: backend.problem);
    final serverPid = sup.children.single.pid!;
    expect(await backend.stop(), isA<Ended>());
    expect(backend.phase, isA<BackendIdle>());
    expect(_alive(serverPid), isFalse);
    // And at quit: closed, the outcome returned.
    expect(await backend.ensureStarted(), isNotNull);
    final again = sup.children.single.pid!;
    expect(await backend.close(unloadWithin: const Duration(milliseconds: 200)), isA<Ended>());
    expect(backend.phase, isA<BackendClosed>());
    expect(_alive(again), isFalse);
  }, skip: skipNoPython);

  test("another running EveryAI's server on the same data is refused, never killed", () async {
    final dir = await Directory.systemTemp.createTemp('local_backend_test');
    addTearDown(() => dir.delete(recursive: true));
    final sup = ProcessSupervisor.create(
      ledgerDir: '${dir.path}/ledger',
      hooks: const SupervisorHooks(timings: fast),
    );
    // Stand-ins: "the other app" and "its server".
    final app = await Process.start('sleep', ['32.$pid']);
    final server = await Process.start('sleep', ['32.$pid']);
    addTearDown(() {
      app.kill(ProcessSignal.sigkill);
      server.kill(ProcessSignal.sigkill);
    });
    String start(int p) => startToken(
      '${Process.runSync('ps', ['-o', 'lstart=', '-p', '$p'], environment: const {'LC_ALL': 'C'}).stdout}',
    );
    final data = Directory('${dir.path}/data')..createSync();
    File('${data.path}/server.owner.json')
        .writeAsStringSync('{"app":"${app.pid}:${start(app.pid)}","pid":${server.pid},"start":"${start(server.pid)}"}');
    final backend = IoLocalBackend(binary: fakeBackend(dir).path, dataDir: data.path, supervisor: sup);
    expect(await backend.ensureStarted(), isNull);
    expect(backend.phase, isA<BackendBlocked>());
    expect(backend.problem, contains('Another EveryAI'));
    expect(_alive(server.pid), isTrue);
    expect(sup.children, isEmpty);
  }, skip: skipNoPython);

  test('a dead run\'s record whose pid is gone is cleared and the server starts', () async {
    final dir = await Directory.systemTemp.createTemp('local_backend_test');
    addTearDown(() => dir.delete(recursive: true));
    final sup = ProcessSupervisor.create(
      ledgerDir: '${dir.path}/ledger',
      hooks: const SupervisorHooks(timings: fast),
    );
    final data = Directory('${dir.path}/data')..createSync();
    File('${data.path}/server.owner.json').writeAsStringSync('{"app":"1:x","pid":999999,"start":"x"}');
    final backend = IoLocalBackend(binary: fakeBackend(dir).path, dataDir: data.path, supervisor: sup);
    expect(await backend.ensureStarted(), isNotNull, reason: backend.problem);
    expect(await backend.stop(), isA<Ended>());
  }, skip: skipNoPython);

  test('the phase table: a stop that is not proven ends NotClosed, which only a stop leaves', () {
    expect(
      nextBackendPhase(const BackendStopping(), const BackendStopNotClosed(Survived([5], 'x'))),
      isA<BackendNotClosed>(),
    );
    expect(nextBackendPhase(const BackendNotClosed('x'), const BackendStartAsked()), isNull);
    expect(nextBackendPhase(const BackendNotClosed('x'), const BackendStopAsked()), isA<BackendStopping>());
    expect(nextBackendPhase(const BackendStarting(), const BackendHeldElsewhere('x')), isA<BackendBlocked>());
    expect(nextBackendPhase(const BackendBlocked('x'), const BackendStartAsked()), isA<BackendStarting>());
    assertOnRefusedBackendTransition = false;
    addTearDown(() => assertOnRefusedBackendTransition = true);
    refusedBackendTransitions.clear();
    expect(applyBackendEvent(const BackendIdle(), const BackendExited('x')), isNull);
    expect(refusedBackendTransitions, hasLength(1));
  });

  test('IoLocalBackend reports a missing binary', () async {
    final backend = IoLocalBackend(binary: null, dataDir: Directory.systemTemp.path);
    // No EVERYAI_BACKEND_BIN and no build next to the test runner.
    if (findLocalBackend() != null) return;
    expect(await backend.ensureStarted(), isNull);
    expect(backend.problem, contains("doesn't include"));
  });
}
