// Live check: a session survives the agent-server restarting on a new port
// with a new key, without duplicating history. Run explicitly:
//
//   AGENT_SERVER_BIN=… AGENT_SERVER_HOME=… CONVERSATION=… \
//   flutter test tool/agent_eval/restart_check_test.dart
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/openhands_harness.dart';
import 'package:flutter_test/flutter_test.dart';

Future<(Process, Uri, String)> _serve(String bin, String home) async {
  final port = 20000 + Random().nextInt(20000);
  final key = List.generate(16, (_) => Random().nextInt(16).toRadixString(16)).join();
  final p = await Process.start(
    bin,
    ['--host', '127.0.0.1', '--port', '$port'],
    workingDirectory: home,
    environment: {'OH_SESSION_API_KEYS_0': key, 'OH_SECRET_KEY': File('$home/secret').readAsStringSync().trim()},
  );
  unawaited(p.stdout.drain<void>());
  unawaited(p.stderr.drain<void>());
  final url = Uri.parse('http://127.0.0.1:$port/');
  final client = HttpClient();
  for (var i = 0; i < 120; i++) {
    try {
      final res = await (await client.getUrl(url.resolve('ready'))).close();
      if (res.statusCode == 200) return (p, url, key);
    } on Object {
      // starting
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  throw StateError('agent-server did not start');
}

void main() {
  final env = Platform.environment;
  test('restart', () async {
    final bin = env['AGENT_SERVER_BIN']!, home = env['AGENT_SERVER_HOME']!, conv = env['CONVERSATION']!;
    var (proc, url, key) = await _serve(bin, home);
    final harness = OpenHandsHarness.located(() async => (url, key));
    final session = await harness.attach(conv);
    final got = <HarnessEvent>[];
    final sub = session.events.listen(got.add);
    addTearDown(() => proc.kill());
    Future<void> settle() async {
      var last = -1;
      while (last != got.length) {
        last = got.length;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }

    await settle();
    final before = [
      for (final e in got)
        if (e.id.isNotEmpty) e.id,
    ];
    print('before restart: ${before.length} events, status ${await harness.statuses([conv])}');

    proc.kill();
    await proc.exitCode;
    final firstPort = url.port;
    (proc, url, key) = await _serve(bin, home);
    print('restarted: :$firstPort -> :${url.port}');
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (got.whereType<ConnectionChange>().where((c) => c.connected).length < 2) {
      if (DateTime.now().isAfter(deadline)) fail('did not reconnect');
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await settle();
    final after = [
      for (final e in got)
        if (e.id.isNotEmpty) e.id,
    ];
    print(
      'after: ${after.length} events, connection ${got.whereType<ConnectionChange>().map((c) => c.connected).toList()}',
    );
    print('status ${await harness.statuses([conv])}');
    final extra = [
      for (final e in got.skip(before.length))
        if (e.id.isNotEmpty) '${e.raw['kind']}${e is StateChange ? ':${e.key}' : ''}',
    ];
    print('new after reconnect: $extra');
    expect(after.toSet().length, after.length, reason: 'no duplicates');
    expect(after.take(before.length).toList(), before, reason: 'nothing lost or reordered');
    // Only state snapshots may be new: the server sends one per connection.
    expect(got.skip(before.length).where((e) => e.id.isNotEmpty && e is! StateChange), isEmpty);
    await sub.cancel();
    await session.close();
    proc.kill();
  }, timeout: Timeout.none);
}
