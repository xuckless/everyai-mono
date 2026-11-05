import 'dart:async';
import 'dart:convert';

import 'package:every_ai/features/remote/data/host_bridge.dart';
import 'package:every_ai/features/remote/data/host_link.dart';
import 'package:every_ai/features/remote/domain/remote_crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket/testing.dart';
import 'package:web_socket/web_socket.dart';

void main() {
  test('a webhook notice is handed over, malformed ones are ignored, and the ack goes back as text', () async {
    final identity = await RemoteIdentity.generate();
    final relaySide = Completer<WebSocket>();
    final fromHost = StreamController<String>();
    final got = <WebhookDelivery>[];
    final arrived = StreamController<WebhookDelivery>();
    final link = RemoteHostLink(
      url: Uri.parse('ws://backend/v1/remote/host'),
      token: 'rh_token',
      connect: (url, token) async {
        final (mine, theirs) = fakes();
        mine.events.listen((e) {
          if (e case TextDataReceived(:final text)) fromHost.add(text);
        });
        relaySide.complete(mine);
        return theirs;
      },
      approvedKey: (_) => null,
      bridge: (send) => HostBridge(identity: identity, hostId: 'host-1', send: send, onMessage: (_, _) {}),
      onWebhook: (d) {
        got.add(d);
        arrived.add(d);
      },
    )..start();
    addTearDown(link.close);
    addTearDown(fromHost.close);
    addTearDown(arrived.close);
    final relay = await relaySide.future;
    final next = StreamIterator(arrived.stream);

    // Malformed: no id, a body that isn't base64, not JSON at all. Then a good one.
    relay.sendText(jsonEncode({'type': 'webhook', 'hook_id': 'h', 'body_b64': ''}));
    relay.sendText(jsonEncode({'type': 'webhook', 'delivery_id': 'x', 'hook_id': 'h', 'body_b64': '%%%'}));
    relay.sendText('{"type":"webhook"');
    relay.sendText(
      jsonEncode({
        'type': 'webhook',
        'delivery_id': 'd-1',
        'hook_id': 'hook-1',
        'hook_name': 'CI',
        'received_at': 1800000000,
        'headers': {'X-GitHub-Event': 'issues', 'content-type': 'application/json', 'n': 3},
        'body_b64': base64Encode(utf8.encode('{"a":1}')),
      }),
    );
    expect(await next.moveNext(), isTrue);
    final d = next.current;
    expect(got, hasLength(1));
    expect(d.id, 'd-1');
    expect(d.hookId, 'hook-1');
    expect(d.hookName, 'CI');
    expect(utf8.decode(d.body), '{"a":1}');
    expect(d.event, 'issues');
    expect(d.headers, {'x-github-event': 'issues', 'content-type': 'application/json'});
    expect(d.receivedAt, DateTime.fromMillisecondsSinceEpoch(1800000000 * 1000));

    link.ackWebhook('d-1');
    final sent = StreamIterator(fromHost.stream);
    expect(await sent.moveNext(), isTrue);
    expect(jsonDecode(sent.current), {'type': 'webhook_ack', 'delivery_id': 'd-1'});
    await next.cancel();
    await sent.cancel();
  });
}
