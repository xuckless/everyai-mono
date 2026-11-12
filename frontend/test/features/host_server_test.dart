import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/code/harness/everyai/mcp_io.dart';
import 'package:every_ai/features/code/host/host.dart';
import 'package:every_ai/features/code/host/host_script.dart' show hostScriptsAvailable;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Timers the test fires by hand.
final class _FakeTimer implements Timer {
  _FakeTimer(this.after, this._fire);
  final Duration after;
  final void Function() _fire;
  var _active = true;

  void fire() {
    if (!_active) return;
    _active = false;
    _fire();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}

/// Answers memory at once; holds every other call until the test answers.
final class _FakeTools implements HostTools {
  final calls = <HostCall>[];
  final held = <String, Completer<HostResult>>{};
  final _ready = <HostCall>[];
  final _waiting = <Completer<HostCall>>[];

  /// The next held call, whether it came before or after this is asked.
  Future<HostCall> get arrived {
    if (_ready.isNotEmpty) return Future.value(_ready.removeAt(0));
    final w = Completer<HostCall>();
    _waiting.add(w);
    return w.future;
  }

  @override
  Future<HostResult> call(HostCall call) {
    calls.add(call);
    if (call.name == 'memory') return Future.value((text: 'saved: ${call.args['text']}', isError: false));
    if (call.name == 'fork') return Future.value((text: 'Started fork f1.', isError: false));
    if (call.name == 'screenshot') {
      call.images.add((mime: 'image/png', data: 'iVBORw0KGgo='));
      return Future.value((text: 'Screenshot of Counter: /p/shot.png.', isError: false));
    }
    final c = held[call.id] = Completer();
    if (_waiting.isNotEmpty) {
      _waiting.removeAt(0).complete(call);
    } else {
      _ready.add(call);
    }
    return c.future;
  }
}

void main() {
  late DateTime clock;
  late List<_FakeTimer> timers;
  late HostServer server;
  late _FakeTools tools;
  late HostToken tok;
  void Function()? onNow;
  const held = Duration(seconds: 300);

  setUp(() async {
    clock = DateTime(2026, 11, 4);
    timers = [];
    onNow = null;
    server = createHostServer(
      idleLimit: const Duration(hours: 1),
      heldLimit: held,
      now: () {
        onNow?.call();
        return clock;
      },
      timer: (after, fire) {
        final t = _FakeTimer(after, fire);
        timers.add(t);
        return t;
      },
    );
    tools = _FakeTools();
    tok = await server.mint('s1', tools);
  });

  tearDown(() => server.stop());

  Future<http.Response> post(Object? body, {String? token, Map<String, String> headers = const {}}) => http.post(
    tok.url,
    headers: {
      'Content-Type': 'application/json',
      'Accept': 'application/json, text/event-stream',
      'Authorization': 'Bearer ${token ?? tok.token}',
      ...headers,
    },
    body: jsonEncode(body),
  );

  Map<String, Object?> rpc(String method, [Map<String, Object?> params = const {}, Object id = 1]) => {
    'jsonrpc': '2.0',
    'id': id,
    'method': method,
    'params': params,
  };

  /// The JSON-RPC reply in an SSE body.
  Map<String, Object?> sseReply(String body) =>
      jsonDecode(const LineSplitter().convert(body).lastWhere((l) => l.startsWith('data:')).substring(5))
          as Map<String, Object?>;

  Map<String, Object?> resultOf(http.Response r) =>
      (r.headers['content-type']!.contains('event-stream') ? sseReply(r.body) : jsonDecode(r.body) as Map)['result']
          as Map<String, Object?>;

  Object? errorCode(http.Response r) => ((jsonDecode(r.body) as Map)['error'] as Map)['code'];

  _FakeTimer heldTimer() => timers.firstWhere((t) => t.after == held);

  test('our own MCP client lists the tools in a fixed order and calls one', () async {
    final c = await McpConnection.open('everyai', {
      'url': '${tok.url}',
      'headers': {'Authorization': 'Bearer ${tok.token}'},
    });
    addTearDown(c.close);
    expect(
      [for (final t in c.tools) t['name']],
      [
        'ask_user_question',
        'present_plan',
        'security_alert',
        'memory',
        'saved_plans',
        'fork',
        'check_forks',
        'answer_fork',
        'stop_fork',
        'message_fork',
        'end_workflow',
        'bug_check',
        'check',
        'diff_stats',
        'diagnostics',
        'goal_check',
        if (hostScriptsAvailable) 'run_script',
        'run_workflow',
        'workflow_agents',
        'report_issue',
        'browser',
        'screenshot',
        'app_run',
        'app',
      ],
    );
    expect(c.tools.first['description'], contains('come back as the result of this call'));
    expect(c.tools.first['inputSchema'], isA<Map<String, Object?>>());
    final out = await c.call('memory', {'action': 'add', 'text': '- run make'});
    expect(out.text, 'saved: - run make');
    expect(out.isError, isFalse);
    expect(tools.calls.single.sessionId, 's1');
  });

  test('a workflow agent\'s token lists and runs only its tools', () async {
    final w = await server.mint('wf', tools, only: workflowHostTools);
    final c = await McpConnection.open('everyai', {
      'url': '${w.url}',
      'headers': {'Authorization': 'Bearer ${w.token}'},
    });
    addTearDown(c.close);
    expect(
      [for (final t in c.tools) t['name']],
      ['security_alert', 'bug_check', 'check', 'diff_stats', 'diagnostics', 'report_issue'],
    );
    for (final name in ['fork', 'run_workflow', 'workflow_agents', 'ask_user_question', 'present_plan', 'memory']) {
      final r = await post(rpc('tools/call', {'name': name, 'arguments': <String, Object?>{}}), token: w.token);
      expect(errorCode(r), -32602, reason: name);
      expect(r.body, contains('Unknown tool'), reason: name);
    }
    expect(tools.calls, isEmpty);
  });

  test('a missing, wrong, revoked or expired token is a 401', () async {
    Future<void> rejected(http.Response r) async {
      expect(r.statusCode, 401);
      expect(r.headers['www-authenticate'], startsWith('Bearer'));
    }

    await rejected(await http.post(tok.url, body: jsonEncode(rpc('ping'))));
    await rejected(await post(rpc('ping'), token: '${tok.token}x'));

    final other = await server.mint('s2', tools);
    await server.revoke(other.token);
    await rejected(await post(rpc('ping'), token: other.token));

    // touch keeps a token alive across the idle limit; without it, it expires.
    clock = clock.add(const Duration(minutes: 50));
    server.touch(tok.token);
    clock = clock.add(const Duration(minutes: 50));
    expect((await post(rpc('ping'))).statusCode, 200);
    clock = clock.add(const Duration(minutes: 61));
    await rejected(await post(rpc('ping')));
  });

  test('the server closes when the last token expires without any request', () async {
    final port = tok.url.port;
    clock = clock.add(const Duration(hours: 1));
    timers.lastWhere((t) => t.isActive && t.after == const Duration(hours: 1)).fire();
    await server.revoke('none'); // waits for the close queued before it
    await expectLater(Socket.connect(InternetAddress.loopbackIPv4, port), throwsA(isA<SocketException>()));
  });

  group('reached from an environment', () {
    /// A POST to [url] (the main listener) naming [host] in its Host header.
  });

  test('a foreign Host or Origin is a 403 (DNS rebinding)', () async {
    expect((await post(rpc('ping'), headers: {'Origin': 'http://evil.example'})).statusCode, 403);
    expect((await post(rpc('ping'), headers: {'Origin': 'http://localhost:${tok.url.port}'})).statusCode, 200);
    final c = HttpClient();
    addTearDown(c.close);
    final req = await c.postUrl(tok.url);
    req.headers
      ..host = 'evil.example'
      ..set('authorization', 'Bearer ${tok.token}');
    req.write(jsonEncode(rpc('ping')));
    final res = await req.close();
    await res.drain<void>();
    expect(res.statusCode, 403);
  });

  group('2026-07-28 requests (from the spec text)', () {});

  Future<http.Response> ask() => post(
    rpc('tools/call', {
      'name': 'ask_user_question',
      'arguments': {'questions': <Object?>[]},
    }, 7),
  );

  test('a held call waits for the answer', () async {
    final reply = ask();
    final call = await tools.arrived;
    expect(call.name, 'ask_user_question');
    tools.held[call.id]!.complete((text: 'Postgres', isError: false));
    final result = resultOf(await reply);
    expect(((result['content'] as List).single as Map)['text'], 'Postgres');
    expect(result['isError'], isFalse);
  });

  test('a held call times out with an error result', () async {
    final reply = ask();
    final call = await tools.arrived;
    heldTimer().fire();
    final result = resultOf(await reply);
    expect(((result['content'] as List).single as Map)['text'], startsWith('Error (timeout)'));
    expect(result['isError'], isTrue);
    expect(await call.ended, HostEnd.timedOut);
    tools.held[call.id]!.complete((text: 'late', isError: false)); // ignored
  });

  test('closing the session ends its pending calls and its token', () async {
    final reply = ask();
    final call = await tools.arrived;
    await server.revokeSession('s1');
    final result = resultOf(await reply);
    expect(((result['content'] as List).single as Map)['text'], 'Error: the EveryAI session ended.');
    expect(await call.ended, HostEnd.sessionClosed);
  });

  test('a token revoked while its call body is read runs nothing', () async {
    await server.mint('s2', tools); // keeps the server up
    final c = HttpClient();
    addTearDown(() => c.close(force: true));
    final body = utf8.encode(
      jsonEncode(
        rpc('tools/call', {
          'name': 'memory',
          'arguments': {'action': 'add', 'text': 'x'},
        }),
      ),
    );
    final req = await c.postUrl(tok.url);
    req.headers
      ..contentType = ContentType.json
      ..set('authorization', 'Bearer ${tok.token}');
    req.contentLength = body.length;
    final authed = Completer<void>();
    onNow = () {
      if (!authed.isCompleted) authed.complete();
    };
    req.add(body.sublist(0, 10));
    await req.flush();
    await authed.future; // the server checked the token and now reads the body
    onNow = null;
    await server.revokeSession('s1');
    req.add(body.sublist(10));
    final res = await req.close();
    await res.drain<void>();
    expect(res.statusCode, 401);
    expect(tools.calls, isEmpty);
  });
}
