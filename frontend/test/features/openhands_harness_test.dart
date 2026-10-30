import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/openhands_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// A stand-in agent-server: one conversation, an event socket that replays
/// [events] (like `resend_mode=all`) and can be dropped from the test.
final class _FakeServer {
  _FakeServer._(this._server);

  static Future<_FakeServer> start() async {
    final s = _FakeServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    s._server.listen(s._handle);
    return s;
  }

  final HttpServer _server;
  final events = <Map<String, Object?>>[];
  final sockets = <WebSocket>[];
  final auths = <String>[];

  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}/');

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    if (path.startsWith('/sockets/events/conv-1')) {
      final ws = await WebSocketTransformer.upgrade(req);
      sockets.add(ws);
      ws.listen((frame) => auths.add((jsonDecode(frame as String) as Map)['session_api_key'] as String));
      for (final e in events) {
        ws.add(jsonEncode(e));
      }
      return;
    }
    if (path == '/api/conversations/conv-1') {
      req.response.write(jsonEncode({'id': 'conv-1', 'execution_status': 'idle'}));
    } else if (path == '/api/conversations') {
      req.response.write(
        jsonEncode([
          {'id': 'conv-1', 'execution_status': 'waiting_for_confirmation'},
        ]),
      );
    } else {
      req.response.statusCode = 404;
      req.response.write('{"detail":"Not Found"}');
    }
    await req.response.close();
  }

  /// Sends one more event to every open socket.
  void push(Map<String, Object?> e) {
    events.add(e);
    for (final ws in sockets) {
      ws.add(jsonEncode(e));
    }
  }

  Future<void> dropSockets() async {
    for (final ws in sockets) {
      await ws.close();
    }
    sockets.clear();
  }

  Future<void> close() => _server.close(force: true);
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

Future<void> _until(bool Function() cond) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test('a listener that subscribes late still gets the whole history', () async {
    final server = await _FakeServer.start();
    addTearDown(server.close);
    server.events.addAll([_msg('e1', 'one'), _msg('e2', 'two')]);
    final session = await OpenHandsHarness(baseUrl: server.url, sessionApiKey: 'k').attach('conv-1');
    addTearDown(session.close);
    await _until(() => server.sockets.isNotEmpty);
    // Give the frames time to arrive before anyone listens.
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final got = <HarnessEvent>[];
    final sub = session.events.listen(got.add);
    addTearDown(sub.cancel);
    await _until(() => got.whereType<ChatMessage>().length == 2);
    expect(got.whereType<ConnectionChange>().last.connected, isTrue);
    expect(server.auths, ['k']);
  });

  test('a dropped socket reconnects, skips resent events and reports the gap', () async {
    final server = await _FakeServer.start();
    addTearDown(server.close);
    server.events.add(_msg('e1', 'one'));
    final session = await OpenHandsHarness(baseUrl: server.url, sessionApiKey: 'k').attach('conv-1');
    addTearDown(session.close);
    final got = <HarnessEvent>[];
    final sub = session.events.listen(got.add);
    addTearDown(sub.cancel);
    await _until(() => got.whereType<ChatMessage>().length == 1);

    await server.dropSockets();
    await _until(() => got.whereType<ConnectionChange>().any((c) => !c.connected));
    // The server resends e1 on reconnect; only e2 is new.
    await _until(() => server.sockets.isNotEmpty);
    server.push(_msg('e2', 'two'));
    await _until(() => got.whereType<ChatMessage>().length == 2);
    expect(got.whereType<ChatMessage>().map((m) => m.text), ['one', 'two']);
    expect(got.whereType<ConnectionChange>().map((c) => c.connected), [true, false, true]);
  });

  test('after the sidecar restarts on another port, the session follows it', () async {
    final first = await _FakeServer.start();
    final second = await _FakeServer.start();
    addTearDown(second.close);
    first.events.add(_msg('e1', 'one'));
    second.events.addAll([_msg('e1', 'one'), _msg('e2', 'two')]);
    var current = first;
    final harness = OpenHandsHarness.located(() async => (current.url, current == first ? 'k1' : 'k2'));
    final session = await harness.attach('conv-1');
    addTearDown(session.close);
    final got = <HarnessEvent>[];
    final sub = session.events.listen(got.add);
    addTearDown(sub.cancel);
    await _until(() => got.whereType<ChatMessage>().length == 1);

    current = second;
    await first.close();
    await first.dropSockets();
    await _until(() => got.whereType<ChatMessage>().length == 2 && second.auths.isNotEmpty);
    expect(second.auths, ['k2']);
  });

  test('a conversation the server no longer has fails to attach clearly', () async {
    final server = await _FakeServer.start();
    addTearDown(server.close);
    final harness = OpenHandsHarness(baseUrl: server.url, sessionApiKey: 'k');
    await expectLater(harness.attach('gone'), throwsA(isA<HarnessError>().having((e) => e.status, 'status', 404)));
  });

  test('statuses come back for many conversations at once', () async {
    final server = await _FakeServer.start();
    addTearDown(server.close);
    final harness = OpenHandsHarness(baseUrl: server.url, sessionApiKey: 'k');
    expect(await harness.statuses(['conv-1']), {'conv-1': ExecutionStatus.waitingForConfirmation});
    expect(await harness.statuses(const []), isEmpty);
  });
}
