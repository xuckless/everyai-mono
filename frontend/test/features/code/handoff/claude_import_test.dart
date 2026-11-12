import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:every_ai/core/process/supervisor.dart' show Ended, KillOutcome;
import 'package:every_ai/features/code/drivers/claude/claude_driver.dart';
import 'package:every_ai/features/code/drivers/json_rpc.dart';
import 'package:every_ai/features/code/handoff/native/claude_import.dart';
import 'package:flutter_test/flutter_test.dart';

import 'native_source.dart';

/// A CLI that takes what it is sent and says nothing.
final class _Quiet implements LineChannel {
  final sent = <String>[];
  final _lines = StreamController<String>();
  @override
  Stream<String> get lines => _lines.stream;
  @override
  String get lastError => '';
  @override
  void send(String line) => sent.add(line);
  @override
  Future<KillOutcome> close() async {
    await _lines.close();
    return const Ended([]);
  }
}

List<Map<String, Object?>> _records(String text) => [
  for (final l in const LineSplitter().convert(text))
    if (l.trim().isNotEmpty) jsonDecode(l) as Map<String, Object?>,
];

void main() {
  late Directory tmp;
  late String work;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('claude_import_test');
    work = '${tmp.resolveSymbolicLinksSync()}/repo';
    Directory(work).createSync();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('writes under the config folder by the real path, adopts it, and the first message resumes it', () async {
    final link = '${tmp.path}/link';
    Link(link).createSync(work);
    final config = '${tmp.path}/claude-config';
    final data = '${tmp.path}/data';
    final quiet = _Quiet();
    final spawned = <List<String>>[];
    final driver = ClaudeDriver(
      dataDir: () async => data,
      spawn: (args, {required cwd, required env, required sessionTag, required logPath}) async {
        spawned.add(args);
        return quiet;
      },
    );
    final env = {'CLAUDE_CONFIG_DIR': config, 'HOME': '${tmp.path}/home'};
    final imported = await ClaudeImporter(
      driver: driver,
      env: (name) async => env[name],
    ).write(source(to: 'claude-code', dir: link));
    expect(imported, isNotNull);
    final id = imported!.nativeId;
    expect(imported.note, 'Imported 2 turns into Claude Code');
    final file = File('$config/projects/${claudeProjectSlug(work)}/$id.jsonl');
    expect(file.existsSync(), isTrue, reason: 'slug of the real path ${claudeProjectSlug(work)}');
    expect(claudeProjectSlug('/private/tmp/a_b.c'), '-private-tmp-a-b-c');
    final records = _records(file.readAsStringSync());
    expect(records.map((r) => r['sessionId']).toSet(), {id});
    expect(records.first['cwd'], work);

    final session = await driver.attach(id);
    await session.send('Finish it.');
    expect(spawned, hasLength(1));
    final at = spawned.single.indexOf('--resume');
    expect(spawned.single[at + 1], id);
    expect(spawned.single, isNot(contains('--session-id')));
    await session.close();
  });
}
