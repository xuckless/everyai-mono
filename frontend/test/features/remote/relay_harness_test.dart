import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/harness/openhands_harness.dart';
import 'package:every_ai/features/remote/data/host_bridge.dart';
import 'package:every_ai/features/remote/data/host_link.dart';
import 'package:every_ai/features/remote/data/relay_client.dart';
import 'package:every_ai/features/remote/domain/remote_crypto.dart';
import 'package:every_ai/features/remote/domain/remote_protocol.dart';
import 'package:every_ai/features/remote/relay_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket/testing.dart';
import 'package:web_socket/web_socket.dart';

/// The backend relay in memory, as remote.zig behaves: host frames carry a
/// 4-byte channel, client frames are bare, text frames are notices. Every
/// binary frame is recorded so the test can check nothing readable crosses.
/// Sends to a socket the other end may have closed already (test teardown).
void _quietly(void Function() send) {
  try {
    send();
  } on WebSocketConnectionClosed {
    // Gone.
  }
}

final class _FakeRelay {
  WebSocket? _host;
  final _clients = <int, (WebSocket, Map<String, Object?>)>{};
  int _next = 7;
  final relayed = <Uint8List>[];

  Future<WebSocket> connectHost(Uri url, String token) async {
    expect(token, 'rh_token');
    final (mine, theirs) = fakes();
    _host = mine;
    mine.events.listen((e) {
      switch (e) {
        case BinaryDataReceived(:final data):
          relayed.add(data);
          final channel = ByteData.sublistView(data, 0, 4).getUint32(0);
          _quietly(() => _clients[channel]?.$1.sendBytes(Uint8List.sublistView(data, 4)));
        case TextDataReceived(:final text):
          final c = jsonDecode(text) as Map<String, Object?>;
          if (c['type'] == 'close_channel') _clients.remove(c['channel'])?.$1.sendText('{"type":"closed"}');
        case CloseReceived():
          if (_host == mine) _hostGone();
      }
    });
    mine.sendText(
      jsonEncode({
        'type': 'hello',
        'host_id': 'host-1',
        'clients': [for (final e in _clients.entries) e.value.$2],
        'pending_pairings': const <Object?>[],
      }),
    );
    for (final c in _clients.values) {
      _quietly(() => c.$1.sendText('{"type":"host_online"}'));
    }
    return theirs;
  }

  RelayConnector connectClient({required String deviceId, required String publicKey}) => (url, token) async {
    expect(url.path, '/v1/remote/client/host-1');
    final (mine, theirs) = fakes();
    final channel = _next++;
    final info = {'channel': channel, 'device_id': deviceId, 'device_name': 'Phone', 'public_key': publicKey};
    _clients[channel] = (mine, info);
    mine.events.listen((e) {
      if (e case BinaryDataReceived(:final data)) {
        relayed.add(data);
        final frame = Uint8List(4 + data.length);
        ByteData.sublistView(frame, 0, 4).setUint32(0, channel);
        frame.setRange(4, frame.length, data);
        _quietly(() => _host?.sendBytes(frame));
      }
    });
    mine.sendText(jsonEncode({'type': 'hello', 'channel': channel, 'host_online': _host != null}));
    _host?.sendText(jsonEncode({'type': 'client_open', ...info}));
    return theirs;
  };

  void _hostGone() {
    _host = null;
    for (final c in _clients.values) {
      _quietly(() => c.$1.sendText('{"type":"host_offline"}'));
    }
  }

  /// The host drops off the relay (quit, sleep, network).
  Future<void> dropHost() async {
    await _host?.close();
    _hostGone();
  }
}

/// A stand-in agent-server: REST under `/api` and the event socket.
final class _AgentServer {
  _AgentServer._(this._server);

  static Future<_AgentServer> start() async {
    final s = _AgentServer._(await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0));
    s._server.listen(s._handle);
    return s;
  }

  final io.HttpServer _server;
  final requests = <(String method, String path, String key, String body)>[];
  final socketFrames = <String>[];
  final sockets = <io.WebSocket>[];

  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}/');

  Future<void> _handle(io.HttpRequest req) async {
    final path = req.uri.path;
    if (path == '/sockets/events/conv-1') {
      final ws = await io.WebSocketTransformer.upgrade(req);
      sockets.add(ws);
      ws.listen((f) => socketFrames.add(f as String));
      ws.add(
        jsonEncode({
          'kind': 'MessageEvent',
          'id': 'e1',
          'source': 'agent',
          'llm_message': {
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': 'Hello from the host'},
            ],
          },
        }),
      );
      return;
    }
    final body = await utf8.decodeStream(req);
    requests.add((req.method, req.uri.toString(), req.headers.value('X-Session-API-Key') ?? '', body));
    if (req.method == 'POST' && path == '/api/conversations') {
      req.response.write(jsonEncode({'id': 'conv-1'}));
    } else if (path == '/api/conversations/conv-1') {
      req.response.write(jsonEncode({'id': 'conv-1', 'execution_status': 'idle'}));
    } else if (path == '/api/conversations') {
      req.response.write(
        jsonEncode([
          {'id': 'conv-1', 'execution_status': 'running'},
        ]),
      );
    } else if (path == '/api/conversations/conv-1/events') {
      req.response.write('{}');
    } else {
      req.response.statusCode = 404;
      req.response.write('{"detail":"Not Found"}');
    }
    await req.response.close();
  }

  Future<void> close() async {
    for (final s in sockets) {
      await s.close();
    }
    await _server.close(force: true);
  }
}

SessionSpec _spec(String dir) => SessionSpec(
  workingDir: dir,
  model: 'anthropic/claude-haiku-5.5',
  mode: AgentMode.ask,
  llmBaseUrl: 'http://backend/v1',
  llmApiKey: 'sk-eai-test',
  sessionTag: 's1',
  initialMessage: 'Add a test',
);

void main() {
  late _FakeRelay relay;
  late _AgentServer server;
  late RemoteIdentity hostKey;
  late RemoteIdentity deviceKey;
  late RemoteHostLink hostLink;
  late RemoteClient client;
  late RelayHarness harness;
  var approved = <String, String>{};

  Future<void> startHost() async {
    hostLink = RemoteHostLink(
      url: Uri.parse('ws://backend/v1/remote/host'),
      token: 'rh_token',
      connect: relay.connectHost,
      approvedKey: (id) => approved[id],
      bridge: (send) => HostBridge(
        identity: hostKey,
        hostId: 'host-1',
        send: send,
        locate: () async => (server.url, 'server-key'),
        projects: () => [(name: 'app', path: '/work/app')],
        allowedDir: (dir) => dir == '/work/app' || dir.startsWith('/work/app/'),
      ),
    )..start();
  }

  setUp(() async {
    relay = _FakeRelay();
    server = await _AgentServer.start();
    hostKey = await RemoteIdentity.generate();
    deviceKey = await RemoteIdentity.generate();
    approved = {'dev-1': deviceKey.publicKeyBase64};
    await startHost();
    client = RemoteClient(
      hostId: 'host-1',
      hostPublicKey: hostKey.publicKey,
      identity: deviceKey,
      deviceToken: 'rd_token',
      relayUrl: Uri.parse('ws://backend/v1/remote/client/host-1'),
      connect: relay.connectClient(deviceId: 'dev-1', publicKey: deviceKey.publicKeyBase64),
      readyTimeout: const Duration(seconds: 3),
    );
    harness = RelayHarness(client);
  });

  tearDown(() async {
    await client.close();
    await hostLink.close();
    await server.close();
  });

  test('a session starts on the host, streams its events and takes messages', () async {
    final session = await harness.start(_spec(remotePath('host-1', '/work/app')));
    expect(session.id, 'conv-1');
    expect(client.status, RemoteLinkStatus.ready);

    final message = await session.events
        .where((e) => e is ChatMessage)
        .cast<ChatMessage>()
        .first
        .timeout(const Duration(seconds: 5));
    expect(message.text, 'Hello from the host');

    await session.send('Also update the README');
    final create = server.requests.firstWhere((r) => r.$1 == 'POST' && r.$2 == '/api/conversations');
    // The host adds its key; the device never had it.
    expect(create.$3, 'server-key');
    // The remote:// path became the folder on the host.
    expect((jsonDecode(create.$4) as Map)['workspace'], {'kind': 'LocalWorkspace', 'working_dir': '/work/app'});
    final sent = server.requests.lastWhere((r) => r.$2 == '/api/conversations/conv-1/events');
    expect(sent.$4, contains('Also update the README'));

    // The socket got the host's auth frame only, not the device's empty one.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(server.socketFrames, [
      jsonEncode({'type': 'auth', 'session_api_key': 'server-key'}),
    ]);

    expect(await harness.statuses(['conv-1']), {'conv-1': ExecutionStatus.running});
    await session.close();
  });

  test('nothing readable crosses the relay', () async {
    final session = await harness.start(_spec(remotePath('host-1', '/work/app')));
    await session.events.where((e) => e is ChatMessage).cast<ChatMessage>().first.timeout(const Duration(seconds: 5));
    final joined = latin1.decode([for (final f in relay.relayed) ...f]);
    for (final secret in ['server-key', 'sk-eai-test', 'Add a test', 'Hello from the host', 'conversations']) {
      expect(joined, isNot(contains(secret)));
    }
    await session.close();
  });

  test('the host lists its projects and refuses folders outside them', () async {
    expect(await client.projects(), [(name: 'app', path: '/work/app')]);
    await expectLater(
      harness.start(_spec('/etc')),
      throwsA(isA<HarnessError>().having((e) => e.status, 'status', 403)),
    );
    await expectLater(
      harness.start(_spec(remotePath('another-host', '/work/app'))),
      throwsA(isA<HarnessError>().having((e) => e.status, 'status', 403)),
    );
    expect(server.requests.where((r) => r.$1 == 'POST'), isEmpty);
  });

  test('a device the host did not approve is not bridged', () async {
    approved = {};
    await hostLink.close();
    await startHost();
    await expectLater(client.projects(), throwsA(isA<RemoteUnavailable>()));
  });

  test('a host with other keys is refused before any request', () async {
    final impostor = await RemoteIdentity.generate();
    await hostLink.close();
    hostKey = impostor;
    await startHost();
    await expectLater(client.projects(), throwsA(isA<RemoteUnavailable>()));
    expect(client.status, RemoteLinkStatus.keyMismatch);
  });

  test('the link comes back when the host does', () async {
    expect(await client.projects(), hasLength(1));
    await relay.dropHost();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(client.status, RemoteLinkStatus.hostOffline);
    // The host reconnects by itself; a request made meanwhile waits for it.
    expect(await client.projects(), hasLength(1));
    expect(client.status, RemoteLinkStatus.ready);
  });

  test('requests fail while the host stays away', () async {
    expect(await client.projects(), hasLength(1));
    await hostLink.close();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(client.status, RemoteLinkStatus.hostOffline);
    await expectLater(client.projects(), throwsA(isA<RemoteUnavailable>()));
    await startHost();
    expect(await client.projects(), hasLength(1));
  });

  test('the host forwards only allowed paths', () async {
    final res = await client.request('POST', 'api/bash/execute_bash_command', body: '{"command":"id"}');
    expect(res.status, 403);
    expect(server.requests, isEmpty);
  });
}
