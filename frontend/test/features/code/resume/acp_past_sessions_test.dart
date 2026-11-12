// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:every_ai/core/process/supervisor.dart' show Ended, KillOutcome;
import 'package:crypto/crypto.dart';
import 'package:every_ai/features/code/drivers/json_rpc.dart';
import 'package:every_ai/features/code/resume/acp_sessions.dart';
import 'package:flutter_test/flutter_test.dart';

String _hash(String dir) => sha256.convert(utf8.encode(dir)).toString();

void main() {
  late Directory tmp;
  late String home;
  late String project;
  late String worktree;

  String chat({String? id, String? dir, String? updated, String kind = 'main', String? hash}) {
    final d = dir ?? project;
    var text = File('test/fixtures/resume/gemini_chat.json').readAsStringSync();
    text = text.replaceAll('__HASH__', hash ?? _hash(d)).replaceAll('__DIR__', d);
    final m = jsonDecode(text) as Map<String, Object?>;
    if (id != null) m['sessionId'] = id;
    if (updated != null) m['lastUpdated'] = updated;
    m['kind'] = kind;
    return jsonEncode(m);
  }

  void put(String folderName, String file, String body) {
    final f = File('$home/.gemini/tmp/$folderName/chats/$file');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(body);
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('acp_resume');
    home = '${tmp.path}/home';
    project = '${tmp.path}/repo';
    worktree = '${tmp.path}/wt/repo-1';
    File('$home/.gemini/projects.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'projects': {project: 'repo', '${tmp.path}/other': 'other'},
        }),
      );
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  group('Gemini CLI chats', () {
    test("lists the folder's and its worktrees' chats, newest first, with their fields", () async {
      put('repo', 'session-a.json', chat(id: 'a', updated: '2026-11-01T10:05:00.000Z'));
      // An older Gemini named the folder by the path's hash.
      put(_hash(worktree), 'session-b.json', chat(id: 'b', dir: worktree, updated: '2026-11-02T09:00:00.000Z'));
      put('other', 'session-c.json', chat(id: 'c', dir: '${tmp.path}/other'));
      put('repo', 'session-d.json', chat(id: 'd', kind: 'subagent'));
      // A chat copied in from another folder carries that folder's hash.
      put('repo', 'session-e.json', chat(id: 'e', hash: _hash('/elsewhere')));
      put('repo', 'session-f.json', '{not json');
      put('repo', 'notes.txt', 'ignored');

      final source = GeminiPastSessions(home: home);
      final list = await source.list('$project/', worktrees: [worktree]);
      expect([for (final s in list) s.nativeId], ['b', 'a']);
      final a = list.last;
      expect(a.harness, 'gemini');
      expect(a.cwd, project);
      expect(a.title, 'Add a greeting to hello.txt');
      expect(a.turns, 2);
      expect(a.model, 'gemini-3.5-pro');
      expect(a.lastActive, DateTime.utc(2026, 11, 1, 10, 5));
      expect(list.first.cwd, worktree);
    });
  });

  group('ACP session/list', () {
    test('lists only when the agent offers list and load, and keeps to the folders', () async {
      final fake = _FakeAgent(
        caps: {
          'loadSession': true,
          'sessionCapabilities': {'list': <String, Object?>{}},
        },
        pages: [
          {
            'sessions': [
              {'sessionId': 's1', 'cwd': project, 'title': 'Fix the build', 'updatedAt': '2026-11-01T10:00:00Z'},
              {'sessionId': 's2', 'cwd': '/elsewhere', 'title': 'Not here'},
            ],
            'nextCursor': 'p2',
          },
          {
            'sessions': [
              {'sessionId': 's3', 'cwd': '$project/', 'updatedAt': '2026-11-03T10:00:00Z'},
            ],
          },
        ],
      );
      final source = acpPastSessions('kimi', open: (_) async => fake.peer)!;
      final list = await source.list(project);
      expect(
        [for (final s in list) (s.nativeId, s.title, s.cwd)],
        [('s3', 'Untitled session', project), ('s1', 'Fix the build', project)],
      );
      expect(fake.calls, ['initialize', 'session/list', 'session/list']);
      expect(fake.listParams.last, {'cwd': project, 'cursor': 'p2'});
      expect(fake.closed, isTrue);
      expect(await source.history(list.first), isEmpty);
    });
  });
}

/// An ACP agent on a fake line channel: answers initialize with [caps] and session/list with [pages] in turn.
final class _FakeAgent implements LineChannel {
  _FakeAgent({required this.caps, this.pages = const []});

  final Map<String, Object?> caps;
  final List<Map<String, Object?>> pages;
  final calls = <String>[];
  final listParams = <Object?>[];
  var closed = false;
  final _out = StreamController<String>();
  late final peer = JsonRpcPeer(this);

  @override
  Stream<String> get lines => _out.stream;

  @override
  String get lastError => '';

  @override
  void send(String line) {
    final m = jsonDecode(line) as Map<String, Object?>;
    final method = m['method'] as String;
    calls.add(method);
    Object? result;
    if (method == 'initialize') {
      result = {'protocolVersion': 1, 'agentCapabilities': caps};
    } else if (method == 'session/list') {
      listParams.add(m['params']);
      final n = listParams.length - 1;
      result = n < pages.length ? pages[n] : {'sessions': <Object?>[]};
    }
    scheduleMicrotask(() => _out.add(jsonEncode({'jsonrpc': '2.0', 'id': m['id'], 'result': result})));
  }

  @override
  Future<KillOutcome> close() async {
    closed = true;
    await _out.close();
    return const Ended([]);
  }
}
