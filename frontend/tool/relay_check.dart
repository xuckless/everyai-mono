// Checks the remote-control relay end to end on a deployed server, e.g.
// through a Cloudflare Tunnel (backend-exp/deploy/docker-compose.tunnel.yml):
//   dart run tool/relay_check.dart https://api.everyai.dev
// Signed out, as a stand-in host and device: registers an anonymous host,
// pairs a device, opens both sockets, sends a frame each way and checks the
// channel prefix, then removes the host. Spends no model calls.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

Future<void> main(List<String> args) async {
  final base = Uri.parse(args.isEmpty ? 'http://127.0.0.1:8080/' : (args[0].endsWith('/') ? args[0] : '${args[0]}/'));
  final http = HttpClient();
  Future<Map<String, Object?>> call(
    String method,
    String path, {
    Object? body,
    Map<String, String> headers = const {},
  }) async {
    final req = await http.openUrl(method, base.resolve(path));
    req.headers.contentType = ContentType.json;
    headers.forEach(req.headers.set);
    if (body != null) req.write(jsonEncode(body));
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode >= 300) throw 'HTTP ${res.statusCode} on $path: $text';
    return text.isEmpty ? const {} : jsonDecode(text) as Map<String, Object?>;
  }

  final ws = base.replace(scheme: base.scheme == 'https' ? 'wss' : 'ws');
  WebSocket? host;
  WebSocket? device;
  String? hostId;
  String? hostToken;
  try {
    final made = await call(
      'POST',
      'v1/remote/hosts',
      body: {'name': 'relay check', 'platform': 'check', 'public_key': 'cmVsYXktY2hlY2s'},
    );
    hostId = made['id']! as String;
    hostToken = made['host_token']! as String;
    final code = await call(
      'POST',
      'v1/remote/pair',
      body: {'host_id': hostId},
      headers: {'X-Remote-Host-Token': hostToken},
    );
    final redeemed = await call(
      'POST',
      'v1/remote/pair/redeem',
      body: {'code': code['code'], 'device_name': 'relay check', 'public_key': 'ZGV2aWNl'},
    );
    await call(
      'POST',
      'v1/remote/pair/${redeemed['id']}/approve',
      body: const {},
      headers: {'X-Remote-Host-Token': hostToken},
    );
    stdout.writeln('ok   paired an anonymous host and device');

    host = await WebSocket.connect(
      ws.resolve('v1/remote/host').toString(),
      headers: {'Authorization': 'Bearer $hostToken'},
    );
    final hostIn = StreamIterator(host);
    Future<Object?> next(StreamIterator<dynamic> it) async {
      if (!await it.moveNext().timeout(const Duration(seconds: 15))) throw 'socket closed';
      return it.current;
    }

    Future<Map<String, Object?>> notice(StreamIterator<dynamic> it, String type) async {
      for (var i = 0; i < 8; i++) {
        final m = await next(it);
        if (m is String && (jsonDecode(m) as Map)['type'] == type) return jsonDecode(m) as Map<String, Object?>;
      }
      throw 'no $type notice';
    }

    await notice(hostIn, 'hello');
    device = await WebSocket.connect(
      ws.resolve('v1/remote/client/$hostId').toString(),
      headers: {'Authorization': 'Bearer ${redeemed['device_token']}'},
    );
    final devIn = StreamIterator(device);
    final hello = await notice(devIn, 'hello');
    final channel = (hello['channel']! as num).toInt();
    stdout.writeln('ok   both sockets open (channel $channel)');

    device.add(Uint8List.fromList(utf8.encode('up')));
    Object? up;
    do {
      up = await next(hostIn);
    } while (up is String);
    final bytes = up! as List<int>;
    final ch = ByteData.sublistView(Uint8List.fromList(bytes.sublist(0, 4))).getUint32(0);
    if (ch != channel || utf8.decode(bytes.sublist(4)) != 'up') throw 'host got ${bytes.length} bytes on channel $ch';
    stdout.writeln('ok   device → host, channel prefix added');

    final down = BytesBuilder()
      ..add((ByteData(4)..setUint32(0, channel)).buffer.asUint8List())
      ..add(utf8.encode('down'));
    host.add(down.takeBytes());
    Object? got;
    do {
      got = await next(devIn);
    } while (got is String);
    if (utf8.decode(got! as List<int>) != 'down') throw 'device got the wrong frame';
    stdout.writeln('ok   host → device, channel prefix stripped');
  } on Object catch (e) {
    stdout.writeln('FAIL $e');
    exitCode = 1;
  } finally {
    await device?.close();
    await host?.close();
    if (hostId != null && hostToken != null) {
      try {
        await call('DELETE', 'v1/remote/hosts/$hostId', headers: {'X-Remote-Host-Token': hostToken});
      } on Object {
        // An anonymous host is pruned after 30 idle days anyway.
      }
    }
    http.close();
  }
}
