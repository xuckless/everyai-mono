import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/code/drivers/codex/codex_driver.dart';
import 'package:every_ai/features/code/drivers/json_rpc.dart';
import 'package:every_ai/features/code/handoff/native/codex_import.dart';
import 'package:every_ai/features/code/handoff/native/import_steps.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/replay_transport.dart';
import 'native_source.dart';

// The handshake as in test/fixtures/drivers/codex/start.jsonl (codex-cli 0.166.0, signed out), then thread/start
// and thread/inject_items as the spike sent them (test/fixtures/drivers/native/codex_inject.jsonl).
String _line(String dir, Map<String, Object?> msg) => jsonEncode({'dir': dir, 'msg': msg});

String _handshake() => [
  _line('out', {
    'id': 1,
    'method': 'initialize',
    'params': {
      'clientInfo': {'name': 'everyai', 'title': 'EveryAI', 'version': '0.1.0'},
      'capabilities': {
        'optOutNotificationMethods': [
          'turn/diff/updated',
          'item/commandExecution/outputDelta',
          'item/fileChange/outputDelta',
        ],
      },
    },
  }),
  _line('in', {
    'id': 1,
    'result': {'userAgent': 'everyai/0.166.0', 'codexHome': '/home/user/.codex'},
  }),
  _line('out', {'method': 'initialized'}),
  _line('out', {'id': 2, 'method': 'account/read', 'params': <String, Object?>{}}),
  _line('in', {
    'id': 2,
    'result': {'account': null, 'requiresOpenaiAuth': true},
  }),
].join('\n');

const _policy = {'approvalPolicy': 'on-request', 'approvalsReviewer': 'user', 'sandbox': 'read-only'};

String _import({Map<String, Object?>? injectError}) => [
  _handshake(),
  _line('out', {
    'id': 3,
    'method': 'thread/start',
    'params': {'cwd': cwd, 'model': 'gpt-5.5-codex', ..._policy},
  }),
  _line('in', {
    'id': 3,
    'result': {
      'thread': {'id': 'thr_1', 'cwd': cwd, 'turns': <Object?>[]},
    },
  }),
  _line('out', {
    'id': 4,
    'method': 'thread/inject_items',
    'params': {'threadId': 'thr_1', 'items': '{{any}}'},
  }),
  if (injectError == null)
    _line('in', {'id': 4, 'result': <String, Object?>{}})
  else ...[
    _line('in', {'id': 4, 'error': injectError}),
    _line('out', {
      'id': 5,
      'method': 'thread/delete',
      'params': {'threadId': 'thr_1'},
    }),
    _line('in', {'id': 5, 'result': <String, Object?>{}}),
  ],
].join('\n');

void main() {
  late Directory tmp;
  late String data;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('codex_import_test');
    data = '${tmp.path}/data';
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  CodexDriver driver(List<LineChannel> channels) => CodexDriver(
    which: (_) async => '/bin/echo',
    dataDir: () async => data,
    spawn: ({required args, required cwd, required env, required sessionTag}) async {
      if (channels.isEmpty) fail('started Codex more often than expected');
      return channels.removeAt(0);
    },
  );

  test('items: shell and apply_patch as the spike injected them, the rest as text, the cut call failed', () {
    final items = codexItems(importSteps(source(), into: 'Codex')!, cwd);
    final spike = [
      for (final l in File('test/fixtures/drivers/native/codex_inject.jsonl').readAsLinesSync())
        jsonDecode(l) as Map<String, Object?>,
    ];
    final spikeItems = (((spike.last['msg']! as Map)['params']! as Map)['items']! as List).cast<Map<String, Object?>>();
    final types = [for (final i in items) '${i['type']}${i['role'] == null ? '' : ':${i['role']}'}'];
    expect(types, [
      'message:user',
      'message:user',
      'custom_tool_call',
      'custom_tool_call_output',
      'message:assistant',
      'message:user',
      'function_call',
      'function_call_output',
      'function_call',
      'function_call_output',
      'message:user',
    ]);
    // The keys of every call and output are the spike's.
    for (final i in items.where((i) => i['type'] != 'message')) {
      final like = spikeItems.firstWhere((s) => s['type'] == i['type']);
      expect(i.keys.toSet(), like.keys.toSet(), reason: '${i['type']}');
    }
    expect(items[2]['input'], '*** Begin Patch\n*** Add File: hello.txt\n+PINEAPPLE\n*** End Patch\n');
    expect(jsonDecode(items[6]['arguments']! as String), {
      'command': ['bash', '-lc', 'echo MANGO > bye.txt'],
      'workdir': cwd,
    });
    expect(items[9]['output'], notFinishedResult);
    expect(
      [for (final i in items.where((i) => i['call_id'] != null)) i['call_id']],
      ['call_imp_1', 'call_imp_1', 'call_imp_2', 'call_imp_2', 'call_imp_3', 'call_imp_3'],
    );
    expect(jsonEncode(items.last), contains('<cut-turn>'));
  });

  test('no inject_items in this Codex (-32601): the thread is deleted and nothing is imported', () async {
    final channel = ReplayChannel(_import(injectError: {'code': -32601, 'message': 'method not found'}));
    expect(await CodexImporter(driver: driver([channel])).write(source()), isNull);
    channel.expectFinished();
    expect(Directory('$data/threads').existsSync(), isFalse);
  });
}
