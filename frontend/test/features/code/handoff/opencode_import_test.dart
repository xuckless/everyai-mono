import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:every_ai/features/code/drivers/opencode/opencode_driver.dart';
import 'package:every_ai/features/code/drivers/opencode/opencode_session.dart' show openCodeSessionRules;
import 'package:every_ai/features/code/drivers/opencode/opencode_server.dart';
import 'package:every_ai/features/code/handoff/native/opencode_import.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'native_source.dart';

const _native = 'test/fixtures/drivers/native';

Map<String, Object?> _json(String name) =>
    jsonDecode(File('$_native/$name').readAsStringSync()) as Map<String, Object?>;

void main() {
  late Directory data;
  setUp(() => data = Directory.systemTemp.createTempSync('opencode_import_test'));
  tearDown(() => data.deleteSync(recursive: true));

  OpenCodeDriver driver(http.Client client) => OpenCodeDriver(
    which: (_) async => '/bin/echo',
    run: (exe, args) async => (exitCode: 0, stdout: '[]'),
    dataDir: () async => data.path,
    reconnectDelay: Duration.zero,
    launch: ({required executable, required cwd, required sessionTag, required logPath, env = const {}}) async =>
        OpenCodeServer(base: Uri.parse('http://127.0.0.1:4096'), password: 'pw', client: client),
  );

  OpenCodeImporter importer(http.Client client) =>
      OpenCodeImporter(driver: driver(client), now: () => DateTime.utc(2026, 11, 4), random: Random(1));

  test('the import body has the spike\'s shape: native tool names, executed false, our marker, ids in order', () async {
    final bodies = <Map<String, Object?>>[];
    final imported = await importer(
      MockClient((r) async {
        expect((r.method, r.url.path), ('POST', '/api/experimental/session/import'));
        bodies.add(jsonDecode(r.body) as Map<String, Object?>);
        return http.Response('{"data":{}}', 200);
      }),
    ).write(source(to: 'opencode', model: 'opencode/big-pickle', effort: 'default'));
    final body = bodies.single;
    final spike = _json('opencode_import_body.json');
    expect(body.keys.toSet(), spike.keys.toSet());
    final info = body['info']! as Map<String, Object?>;
    // The spike's body had no rules; the app's permission rules go in too, as at `start`.
    expect(info.keys.toSet(), {...(spike['info']! as Map).keys, 'permissions'});
    expect(info['permissions'], openCodeSessionRules);
    expect(info['model'], (spike['info']! as Map)['model']);
    expect(body['location'], {'directory': cwd});
    expect(imported?.nativeId, info['id']);
    expect(imported?.note, 'Imported 2 turns into OpenCode');
    final messages = (body['messages']! as List).cast<Map<String, Object?>>();
    final ids = [for (final m in messages) m['id']! as String];
    expect([...ids]..sort(), ids, reason: 'ascending ids');
    expect(ids.every((id) => RegExp(r'^msg_[0-9a-f]{12}[0-9A-Za-z]{14}$').hasMatch(id)), isTrue);
    expect(info['id'], matches(RegExp(r'^ses_[0-9a-f]{12}[0-9A-Za-z]{14}$')));
    for (final m in messages) {
      expect(m['metadata'], {
        'everyai': {'imported': true},
      });
    }
    final spikeTool = ((spike['messages']! as List).cast<Map<String, Object?>>()[1]['content']! as List).first as Map;
    final tools = [
      for (final m in messages)
        for (final p in (m['content'] as List? ?? const []).cast<Map<String, Object?>>())
          if (p['type'] == 'tool') p,
    ];
    expect(tools.map((t) => t['name']), ['write', 'shell', 'shell']);
    for (final t in tools) {
      expect(t.keys.toSet(), spikeTool.keys.toSet());
      expect(t['executed'], isFalse);
      expect((t['state']! as Map).keys.toSet(), (spikeTool['state']! as Map).keys.toSet());
    }
    expect(jsonEncode((tools.first['state']! as Map)['input']), jsonEncode((spikeTool['state']! as Map)['input']));
    expect(((tools.last['state']! as Map)['content']! as List).single, {
      'type': 'text',
      'text': startsWith('Error: (not finished'),
    });
    expect(messages.map((m) => (m['type'], m['finish'])), [
      ('user', null),
      ('user', null),
      ('assistant', 'tool-calls'),
      ('assistant', 'stop'),
      ('user', null),
      ('assistant', 'tool-calls'),
      ('user', null),
    ]);
    expect(messages.last['text'], contains('<cut-turn>'));
    final record = File('${data.path}/driver-sessions/opencode/${info['id']}.json');
    expect(jsonDecode(record.readAsStringSync()), {
      'workingDir': cwd,
      'sessionTag': 'tag-1',
      'model': 'opencode/big-pickle',
      'effort': 'default',
    });
  });
}
