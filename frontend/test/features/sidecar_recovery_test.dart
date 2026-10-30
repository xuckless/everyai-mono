@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/openhands_harness.dart';
import 'package:every_ai/features/code/sidecar/sidecar.dart';
import 'package:every_ai/features/code/sidecar/sidecar_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

Future<void> _until(bool Function() cond, {Duration timeout = const Duration(seconds: 20)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// A stand-in agent-server binary: serves its working directory, which has a
/// `ready` file, on the port it is given.
Future<(String bin, Directory home)> _fakeServerBinary() async {
  final dir = await Directory.systemTemp.createTemp('sidecar-test');
  addTearDown(() => dir.delete(recursive: true));
  final home = await Directory('${dir.path}/home').create();
  await File('${home.path}/ready').writeAsString('ok');
  final bin = File('${dir.path}/agent-server');
  await bin.writeAsString('#!/bin/sh\nexec python3 -m http.server "\$4" --bind "\$2" >/dev/null 2>&1\n');
  await Process.run('chmod', ['+x', bin.path]);
  return (bin.path, home);
}

/// A stand-in agent-server for the harness: conversation `conv-1`, replays
/// [events] to each socket.
final class _FakeAgentServer {
  _FakeAgentServer._(this._server);

  static Future<_FakeAgentServer> start() async {
    final s = _FakeAgentServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    s._server.listen(s._handle);
    return s;
  }

  final HttpServer _server;
  final events = <Map<String, Object?>>[];
  final sockets = <WebSocket>[];

  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}/');

  Future<void> _handle(HttpRequest req) async {
    if (req.uri.path.startsWith('/sockets/events/conv-1')) {
      final ws = await WebSocketTransformer.upgrade(req);
      sockets.add(ws);
      ws.listen((_) {});
      for (final e in events) {
        ws.add(jsonEncode(e));
      }
      return;
    }
    req.response.write(jsonEncode({'id': 'conv-1', 'execution_status': 'idle'}));
    await req.response.close();
  }

  Future<void> close() async {
    for (final ws in sockets) {
      await ws.close();
    }
    await _server.close(force: true);
  }
}

Map<String, Object?> _msg(String id, String text) => {
  'kind': 'MessageEvent',
  'id': id,
  'source': 'agent',
  'llm_message': {
    'role': 'assistant',
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
};

void main() {
  group('CrashPolicy', () {
    test('restarts at once until the crashes come too fast, then waits', () {
      final p = CrashPolicy(limit: 3, window: const Duration(minutes: 1), cooldown: const Duration(seconds: 30));
      final t0 = DateTime(2026, 10, 30, 12);
      p
        ..crashed(t0)
        ..crashed(t0.add(const Duration(seconds: 5)));
      expect(p.blockedUntil(t0.add(const Duration(seconds: 6))), isNull);
      p.crashed(t0.add(const Duration(seconds: 10)));
      expect(p.blockedUntil(t0.add(const Duration(seconds: 11))), t0.add(const Duration(seconds: 40)));
      expect(p.blockedUntil(t0.add(const Duration(seconds: 41))), isNull);
    });

    test('old crashes fall out of the window', () {
      final p = CrashPolicy(limit: 2, window: const Duration(seconds: 10));
      final t0 = DateTime(2026, 10, 30, 12);
      p
        ..crashed(t0)
        ..crashed(t0.add(const Duration(seconds: 20)));
      expect(p.blockedUntil(t0.add(const Duration(seconds: 21))), isNull);
    });
  });

  test('a server that crashes is started again and announced', () async {
    final (bin, home) = await _fakeServerBinary();
    final sidecar = ProcessSidecar(binary: bin, home: home);
    addTearDown(sidecar.stop);
    final restarts = <void>[];
    final sub = sidecar.restarts.listen(restarts.add);
    addTearDown(sub.cancel);

    final first = await sidecar.endpoint();
    expect((await http.get(first.baseUrl.resolve('ready'))).statusCode, 200);
    Process.killPid(sidecar.pid!, ProcessSignal.sigkill);

    await _until(() => restarts.isNotEmpty);
    final second = await sidecar.endpoint();
    expect(second.baseUrl, isNot(first.baseUrl));
    expect(second.sessionApiKey, isNot(first.sessionApiKey));
    expect((await http.get(second.baseUrl.resolve('ready'))).statusCode, 200);
  });

  test('stopping the server on purpose is not a crash', () async {
    final (bin, home) = await _fakeServerBinary();
    final sidecar = ProcessSidecar(binary: bin, home: home);
    final restarts = <void>[];
    final sub = sidecar.restarts.listen(restarts.add);
    addTearDown(sub.cancel);
    await sidecar.endpoint();
    await sidecar.stop();
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(sidecar.pid, isNull);
    expect(restarts, isEmpty);
  });

  test('a session reattaches at once when the server comes back, and says it restarted', () async {
    final first = await _FakeAgentServer.start();
    final second = await _FakeAgentServer.start();
    addTearDown(second.close);
    first.events.add(_msg('e1', 'one'));
    second.events.addAll([_msg('e1', 'one'), _msg('e2', 'two')]);
    var current = first;
    final restarts = StreamController<void>.broadcast();
    addTearDown(restarts.close);
    var down = false;
    final harness = OpenHandsHarness.located(() async {
      if (down) throw const SidecarError('restarting');
      return (current.url, current == first ? 'k1' : 'k2');
    }, restarts: restarts.stream);
    final session = await harness.attach('conv-1');
    addTearDown(session.close);
    final got = <HarnessEvent>[];
    final sub = session.events.listen(got.add);
    addTearDown(sub.cancel);
    await _until(() => got.whereType<ChatMessage>().length == 1);

    // The server dies; reconnects fail and back off for a while.
    down = true;
    await first.close();
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    final before = DateTime.now();
    current = second;
    down = false;
    restarts.add(null);

    await _until(() => got.whereType<ChatMessage>().length == 2, timeout: const Duration(seconds: 5));
    // The backoff alone would have waited until ~4.5 s.
    expect(DateTime.now().difference(before), lessThan(const Duration(seconds: 1)));
    final changes = got.whereType<ConnectionChange>().toList();
    expect(changes.first.restarted, isFalse);
    expect(changes.last.connected, isTrue);
    expect(changes.last.restarted, isTrue);
    expect(got.whereType<ChatMessage>().map((m) => m.text), ['one', 'two']);
  });
}
