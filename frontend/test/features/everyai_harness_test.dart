import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/mcp_tool_check.dart' show mcpToolDigest;
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/everyai/everyai_harness_io.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/harness/everyai/llm.dart';
import 'package:every_ai/features/code/harness/everyai/shell_io.dart';
import 'package:every_ai/features/code/domain/transcript.dart'
    show isOutOfCredits, planApprovedMessage, planApprovedReason;
import 'package:every_ai/features/code/drivers/usage_limit.dart';
import 'package:every_ai/features/code/harness/everyai/scrub.dart';
import 'package:every_ai/features/code/harness/everyai/tools_io.dart';
import 'package:every_ai/features/code/host/host.dart';
import 'package:flutter_test/flutter_test.dart';

/// A stand-in for the gateway: answers each chat completion with the next
/// scripted reply (as an SSE stream) and keeps the requests.
final class FakeGateway {
  FakeGateway._(this._server) {
    _server.listen(_handle);
  }

  final HttpServer _server;
  final replies = <Map<String, Object?>>[];
  final requests = <Map<String, Object?>>[];

  /// How long a streamed reply takes to start (a slow model call).
  var delay = Duration.zero;

  /// What a plain (not streamed) call answers; null: a compaction summary.
  String? plain;

  /// What `/aux/decide` answers, by question id ("unsure" for the rest).
  final decisions = <String, Object?>{};

  /// The decider's requests.
  final decided = <Map<String, Object?>>[];

  static Future<FakeGateway> start() async => FakeGateway._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  String get baseUrl => 'http://127.0.0.1:${_server.port}/v1';

  /// An error reply: HTTP [status] with [error] as the JSON body's `error`.
  void fail(int status, Map<String, Object?> error) => replies.add({'status': status, 'error': error});

  /// A reply with [text] and these tool calls (name, arguments).
  void reply({String text = '', List<(String, Map<String, Object?>)> calls = const []}) => replies.add({
    'text': text,
    'calls': [for (final (name, args) in calls) (name, jsonEncode(args))],
  });

  Future<void> _handle(HttpRequest req) async {
    final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, Object?>;
    if (req.uri.path.endsWith('/aux/decide')) {
      decided.add(body);
      req.response.headers.contentType = ContentType.json;
      req.response.write(
        jsonEncode({
          'answers': [
            for (final q in (body['questions'] as List<Object?>).cast<Map<String, Object?>>())
              {'id': q['id'], 'value': decisions[q['id']] ?? 'unsure'},
          ],
        }),
      );
      await req.response.close();
      return;
    }
    requests.add(body);
    if (body['stream'] != true) {
      // A plain call: the compaction summary.
      req.response.headers.contentType = ContentType.json;
      req.response.write(
        jsonEncode({
          'choices': [
            {
              'message': {
                'content':
                    plain ??
                    '## Objective\nMake hello.py\n## Important details\nnone\n## Work state\nwrote it\n'
                        '## Next move\n1. Run it\n## Relevant files\n- hello.py',
              },
            },
          ],
        }),
      );
      await req.response.close();
      return;
    }
    await Future<void>.delayed(delay);
    final next = replies.isEmpty ? {'text': 'Done.', 'calls': const <(String, String)>[]} : replies.removeAt(0);
    if (next['status'] case final int status) {
      req.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'error': next['error']}));
      await req.response.close();
      return;
    }
    req.response.headers.contentType = ContentType('text', 'event-stream');
    void chunk(Map<String, Object?> delta, {String? finish}) => req.response.write(
      'data: ${jsonEncode({
        'choices': [
          {'index': 0, 'delta': delta, 'finish_reason': ?finish},
        ],
      })}\n\n',
    );
    final text = next['text']! as String;
    if (text.isNotEmpty) {
      chunk({'content': text.substring(0, text.length ~/ 2)});
      chunk({'content': text.substring(text.length ~/ 2)});
    }
    final calls = next['calls']! as List<(String, String)>;
    for (final (i, (name, args)) in calls.indexed) {
      chunk({
        'tool_calls': [
          {
            'index': i,
            'id': 'call_${requests.length}_$i',
            'function': {'name': name, 'arguments': ''},
          },
        ],
      });
      chunk({
        'tool_calls': [
          {
            'index': i,
            'function': {'arguments': args},
          },
        ],
      });
    }
    chunk({}, finish: calls.isEmpty ? 'stop' : 'tool_calls');
    req.response.write('data: {"usage":{"prompt_tokens":1234,"completion_tokens":5}}\n\n');
    req.response.write('data: [DONE]\n\n');
    await req.response.close();
  }

  Future<void> close() => _server.close(force: true);
}

/// The app's side of the host: answers every call, keeping their names.
final class _HostCalls implements HostTools {
  final names = <String>[];

  @override
  Future<HostResult> call(HostCall call) async {
    names.add(call.name);
    return (text: '2 files changed', isError: false);
  }
}

void main() {
  late Directory tmp;
  late String work;
  late FakeGateway gateway;
  late EveryAIHarness harness;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('everyai-harness');
    work = '${tmp.path}/project';
    Directory(work).createSync();
    gateway = await FakeGateway.start();
    harness = EveryAIHarness(dataDir: () async => '${tmp.path}/data', gatewayKey: () async => 'sk-test');
  });
  tearDown(() async {
    await gateway.close();
    await tmp.delete(recursive: true);
  });

  SessionSpec spec(String first, {AgentMode mode = AgentMode.fullAuto, bool vision = false}) => SessionSpec(
    workingDir: work,
    vision: vision,
    model: 'anthropic/claude-sonnet-5.5',
    mode: mode,
    llmBaseUrl: gateway.baseUrl,
    llmApiKey: 'sk-test',
    sessionTag: 'tag-1',
    initialMessage: first,
    holdClientTools: true,
  );

  /// Collects [session]'s events and approves everything that waits, the way
  /// Full auto does; [answer] decides held client tools instead.
  Future<List<HarnessEvent>> drive(
    HarnessSession session, {
    String? Function(ActionCall call)? answer,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final events = <HarnessEvent>[];
    final done = Completer<void>();
    final open = <ActionCall>[];
    late StreamSubscription<HarnessEvent> sub;
    sub = session.events.listen((e) async {
      events.add(e);
      if (e is ActionCall) open.add(e);
      if (e is ToolResult) open.removeWhere((c) => c.id == e.actionId);
      if (e is StateChange && e.executionStatus == ExecutionStatus.waitingForConfirmation) {
        final held = open.where((c) => answer?.call(c) != null).toList();
        if (held.isNotEmpty) {
          await session.respond(accept: false, reason: answer!(held.first));
          await session.resume();
        } else {
          await session.respond(accept: true);
        }
      }
      if (e is StateChange &&
          (e.executionStatus == ExecutionStatus.finished || e.executionStatus == ExecutionStatus.error)) {
        if (!done.isCompleted) done.complete();
      }
    });
    await done.future.timeout(timeout);
    await sub.cancel();
    return events;
  }

  test('runs tools after approval and finishes; the history survives reopening', () async {
    gateway
      ..reply(
        text: 'Creating the file.',
        calls: [
          ('write', {'file_path': 'hello.py', 'content': 'print("hi")\n'}),
        ],
      )
      ..reply(
        calls: [
          ('bash', {'command': 'python3 hello.py'}),
        ],
      )
      ..reply(text: 'It prints hi.');
    final session = await harness.start(spec('make hello.py'));
    final events = await drive(session);

    expect(File('$work/hello.py').readAsStringSync(), 'print("hi")\n');
    final results = events.whereType<ToolResult>().toList();
    expect(results, hasLength(2));
    expect(results.last.text, contains('hi'));
    final calls = events.whereType<ActionCall>().toList();
    expect(calls.first.actionKind, 'WriteFileAction');
    expect(calls.first.str('path'), '$work/hello.py');
    expect(calls.last.actionKind, 'TerminalAction');

    // The second request carries the tool result after the assistant's call.
    final second = gateway.requests[1]['messages']! as List<Object?>;
    expect((second[second.length - 1]! as Map)['role'], 'tool');
    expect((second[second.length - 2]! as Map)['tool_calls'], isNotNull);
    expect((second.first! as Map)['role'], 'system');

    final fresh = EveryAIHarness(dataDir: () async => '${tmp.path}/data', gatewayKey: () async => 'sk-test');
    final reopened = await fresh.attach(session.id);
    final replay = await reopened.events.take(3).toList();
    expect(replay.whereType<ChatMessage>().first.text, 'make hello.py');
  });

  group('usage limits', () {
    tearDown(() => EveryAISession.testRetryPolicy = null);

    test('out of EveryAI credits is a usage limit, not retried, and still reads as out of credits', () async {
      gateway.fail(402, {'message': 'Out of EveryAI credits', 'type': 'insufficient_quota', 'code': 'out_of_credits'});
      final events = await drive(await harness.start(spec('go')));
      final limit = events.map(usageLimitOf).nonNulls.single;
      expect(isOutOfCredits(limit.message), isTrue);
      expect(limit.resetsAt, isNull);
      expect(gateway.requests, hasLength(1));
    });

    test("a key's spent budget is a usage limit with its reset", () async {
      gateway.fail(403, {
        'message': 'Key limit exceeded',
        'code': 403,
        'metadata': {'limit_source': 'openrouter_key_limit', 'resets_at': '2026-11-05T00:00:00Z'},
      });
      final events = await drive(await harness.start(spec('go')));
      expect(events.map(usageLimitOf).nonNulls.single.resetsAt, DateTime.utc(2026, 11, 5));
    });
  });

  test('a held question is answered inside the call and the agent keeps its turn', () async {
    gateway
      ..reply(
        calls: [
          (
            askUserQuestionTool,
            {
              'questions': [
                {
                  'question': 'Which colour?',
                  'header': 'Colour',
                  'options': [
                    {'label': 'Red', 'description': ''},
                    {'label': 'Blue', 'description': ''},
                  ],
                },
              ],
            },
          ),
        ],
      )
      ..reply(text: 'Going with blue.');
    final session = await harness.start(spec('paint it'));
    await drive(session, answer: (c) => c.toolName == askUserQuestionTool ? 'Colour: Blue' : null);

    final last = gateway.requests.last['messages']! as List<Object?>;
    final tool = last.lastWhere((m) => (m! as Map)['role'] == 'tool')! as Map;
    expect(tool['content'], 'Colour: Blue');
    // No extra user message: the answer came back as the call's result.
    expect(last.where((m) => (m! as Map)['role'] == 'user'), hasLength(1));
  });

  test('past the threshold the history is compacted in place and the run carries on', () async {
    gateway
      ..reply(
        calls: [
          ('write', {'file_path': 'hello.py', 'content': 'print(1)\n'}),
        ],
      )
      ..reply(text: 'All done.');
    final session = await harness.start(
      SessionSpec(
        workingDir: work,
        model: 'm',
        mode: AgentMode.fullAuto,
        llmBaseUrl: gateway.baseUrl,
        llmApiKey: 'k',
        sessionTag: 't',
        initialMessage: 'make hello.py',
        // The fake reports 1234 input tokens per call: past 60% of 1000.
        maxInputTokens: 1000,
      ),
    );
    final events = await drive(session);
    final notice = events.whereType<ChatMessage>().where((m) => m.fromUser && m.text.contains('<everyai-compacted>'));
    expect(notice, hasLength(1));
    final last = gateway.requests.last['messages']! as List<Object?>;
    // System prompt, then the continuation message: the old turns are gone.
    expect(last, hasLength(2));
    expect((last[1]! as Map)['content'], contains('## Objective'));
  });

  test('compaction re-injects the todos, the files touched last and loaded skills, and keeps them on disk', () async {
    Directory('$work/skills/tidy').createSync(recursive: true);
    File('$work/skills/tidy/SKILL.md').writeAsStringSync('# Tidy\nAlways sort imports.\n');
    gateway
      ..reply(
        calls: [
          ('read', {'file_path': 'skills/tidy/SKILL.md'}),
          (
            'todo_write',
            {
              'todos': [
                {'content': 'Write hello.py', 'status': 'completed'},
                {'content': 'Run it', 'status': 'in_progress'},
              ],
            },
          ),
          ('write', {'file_path': 'hello.py', 'content': 'print("hello")\n'}),
        ],
      )
      ..reply(text: 'All done.');
    final session = await harness.start(
      SessionSpec(
        workingDir: work,
        model: 'm',
        mode: AgentMode.fullAuto,
        llmBaseUrl: gateway.baseUrl,
        llmApiKey: 'k',
        sessionTag: 't',
        initialMessage: 'make hello.py',
        maxInputTokens: 1000,
      ),
    );
    await drive(session);
    final last = gateway.requests.last['messages']! as List<Object?>;
    final carried = (last[1]! as Map)['content']! as String;
    expect(carried, contains('<todos>\n- [x] Write hello.py\n- [~] Run it\n</todos>'));
    expect(carried, contains('<file path="$work/hello.py">\nprint("hello")'));
    expect(carried, contains('Always sort imports.'));
    expect(carried.indexOf('<files>'), lessThan(carried.indexOf('<skills>')));
    final state = jsonDecode(File('${tmp.path}/data/everyai-sessions/${session.id}/state.json').readAsStringSync());
    expect((state as Map)['touched'], contains('$work/hello.py'));
    expect(state['skills'], ['$work/skills/tidy/SKILL.md']);
  });

  test('a plan approved by a chat message is kept for compaction, like one approved on its card', () async {
    gateway
      ..reply(
        calls: [
          ('present_plan', {'title': 'Add a greeting', 'summary': 'Print hello.'}),
        ],
      )
      ..reply(text: 'Waiting for your go.')
      ..reply(text: 'Building it.');
    final session = await harness.start(spec('add a greeting'));
    // The card is answered with something other than an approval, so the run ends with no plan approved.
    await drive(session, answer: (c) => c.toolName == 'present_plan' ? 'Let me think about it.' : null);
    final dir = '${tmp.path}/data/everyai-sessions/${session.id}';
    Map<String, Object?> state() => jsonDecode(File('$dir/state.json').readAsStringSync()) as Map<String, Object?>;
    expect(state()['approved_plan'] ?? '', isEmpty);
    final run = drive(session);
    await session.send(planApprovedMessage);
    await run;
    expect(state()['approved_plan'], startsWith('# Add a greeting'));
  });

  test('MCP servers over stdio give the agent their tools, images included', () async {
    final server = File('$work/fake_mcp.py')
      ..writeAsStringSync(r'''
import json, sys
PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
for line in sys.stdin:
    m = json.loads(line)
    if "id" not in m: continue
    meth = m["method"]
    if meth == "initialize": r = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "fake"}}
    elif meth == "tools/list": r = {"tools": [{"name": "browser_take_screenshot", "description": "Screenshot the page", "inputSchema": {"type": "object", "properties": {"url": {"type": "string"}}}}]}
    elif meth == "tools/call": r = {"content": [{"type": "text", "text": "shot of " + m["params"]["arguments"].get("url", "")}, {"type": "image", "data": PNG, "mimeType": "image/png"}]}
    else: r = {}
    print(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": r}), flush=True)
''');
    gateway
      ..reply(
        calls: [
          ('browser_take_screenshot', {'url': 'http://localhost:3000'}),
        ],
      )
      ..reply(text: 'Looks right.');
    final session = await harness.start(
      SessionSpec(
        workingDir: work,
        model: 'anthropic/claude-sonnet-5.5',
        mode: AgentMode.fullAuto,
        llmBaseUrl: gateway.baseUrl,
        llmApiKey: 'sk-test',
        sessionTag: 'tag-1',
        initialMessage: 'check the page',
        vision: true,
        mcpConfig: {
          'fake': {
            'command': 'python3',
            'args': [server.path],
          },
        },
      ),
    );
    final events = await drive(session);
    final first = gateway.requests.first;
    final names = [for (final t in first['tools']! as List<Object?>) ((t! as Map)['function']! as Map)['name']];
    expect(names, contains('browser_take_screenshot'));
    final call = events.whereType<ActionCall>().single;
    expect(call.actionKind, 'MCPToolAction');
    expect(events.whereType<ToolResult>().single.text, contains('shot of http://localhost:3000'));
    final second = gateway.requests[1]['messages']! as List<Object?>;
    final last = second.last! as Map;
    expect(jsonEncode(last['content']), contains('data:image/png;base64,'));
    await session.close();
  });

  group('MCP tools are vetted', () {
    final lookup = {
      'name': 'lookup',
      'description': 'Looks a word up',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'word': {'type': 'string'},
        },
      },
    };
    final define = {...lookup, 'name': 'define', 'description': 'Defines a word'};
    late File server;
    setUp(() {
      server = File('$work/dict_mcp.py')
        ..writeAsStringSync('''
import json, sys
TOOLS = json.loads(${jsonEncode(jsonEncode([lookup, define]))})
for line in sys.stdin:
    m = json.loads(line)
    if "id" not in m: continue
    meth = m["method"]
    if meth == "initialize": r = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}}
    elif meth == "tools/list": r = {"tools": TOOLS}
    elif meth == "tools/call": r = {"content": [{"type": "text", "text": "meaning of " + m["params"]["arguments"].get("word", "")}]}
    else: r = {}
    print(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": r}), flush=True)
''');
    });
    Map<String, Object?> dict({Map<String, String>? pinned}) => {
      'dict': {
        'command': 'python3',
        'args': [server.path],
        'pinned': ?pinned,
      },
    };
    List<Object?> toolNames(Map<String, Object?> request) => [
      for (final t in request['tools']! as List<Object?>) ((t! as Map)['function']! as Map)['name'],
    ];

    test('a changed tool is left out, the prompt says so, and results come back wrapped', () async {
      gateway
        ..reply(
          calls: [
            ('lookup', {'word': 'cat'}),
          ],
        )
        ..reply(text: 'Done.');
      final session = await harness.start(
        SessionSpec(
          workingDir: work,
          model: 'anthropic/claude-sonnet-5.5',
          mode: AgentMode.fullAuto,
          llmBaseUrl: gateway.baseUrl,
          llmApiKey: 'sk-test',
          sessionTag: 'tag-1',
          initialMessage: 'what is a cat',
          mcpConfig: dict(pinned: {'lookup': mcpToolDigest(lookup), 'define': 'an older digest'}),
        ),
      );
      final events = await drive(session);
      final first = gateway.requests.first;
      expect(toolNames(first), contains('lookup'));
      expect(toolNames(first), isNot(contains('define')));
      final system = ((first['messages']! as List<Object?>).first! as Map)['content'] as String;
      expect(system, contains('These MCP tools were left out because they changed or look unsafe'));
      expect(system, contains('dict/define'));
      expect(
        events.whereType<ToolResult>().single.text,
        contains('<untrusted-content source="mcp:dict/lookup">\nmeaning of cat\n</untrusted-content>'),
      );
      final report = await (session as ReportsMcpTools).mcpReport;
      expect([for (final p in report['dict']!.pending) p.name], ['define']);
      expect(report['dict']!.pin, isEmpty);
      await session.close();
    });
  });

  test("a briefed session reaches the app's host as everyai__ tools, in place of its own memory", () async {
    final host = createHostServer();
    addTearDown(host.stop);
    final tools = _HostCalls();
    final token = await host.mint('child', tools, only: workflowHostTools);
    gateway
      ..reply(calls: [('everyai__diff_stats', <String, Object?>{})])
      ..reply(text: 'Done.');
    final session = await harness.start(
      SessionSpec(
        workingDir: work,
        model: 'anthropic/claude-sonnet-5.5',
        mode: AgentMode.fullAuto,
        llmBaseUrl: gateway.baseUrl,
        llmApiKey: 'sk-test',
        sessionTag: 'tag-1',
        initialMessage: 'fix the bug',
        // A workflow agent: a child, so no client tools of its own.
        subagent: true,
        briefing: DriverBriefing(mcpUrl: '${token.url}', mcpToken: token.token),
      ),
    );
    final events = await drive(session);
    final names = [
      for (final t in gateway.requests.first['tools']! as List<Object?>) ((t! as Map)['function']! as Map)['name'],
    ];
    expect(names, containsAll(['everyai__bug_check', 'everyai__check', 'everyai__diff_stats']));
    // No memory of its own or the host's: it reads it in its prompt, and the lead decides what is kept.
    expect(names.where((n) => '$n'.contains('memory')), isEmpty);
    expect(names.where((n) => '$n'.contains('fork') || '$n'.contains('run_workflow')), isEmpty);
    final call = events.whereType<ActionCall>().single;
    expect(call.actionKind, 'MCPToolAction');
    expect(call.toolName, 'everyai__diff_stats');
    expect(tools.names, ['diff_stats']);
    expect(events.whereType<ToolResult>().single.text, contains('2 files changed'));
    // The token lives in memory only.
    final spec = File('${tmp.path}/data/everyai-sessions/${session.id}/spec.json').readAsStringSync();
    expect(spec, isNot(contains(token.token)));
    await session.close();
  });

  group('applyEdit', () {});

  test('a research job has no shell, writes only its notes, reads no secrets, and stays on its sites', () async {
    File('$work/.env').writeAsStringSync('API_TOKEN=supersecretvalue123\n');
    final shell = SessionShell(root: work, sessionTag: 't', scratchDir: '${tmp.path}/sh-r');
    final runner = ToolRunner(
      root: work,
      shell: shell,
      gateway: GatewayClient(baseUrl: 'http://127.0.0.1:9/v1', apiKey: 'sk-eai-test-key-000000'),
      sessionTag: 't',
      researchSites: const ['github.com'],
    );
    expect((await runner.run('bash', {'command': 'echo hi'})).text, contains('no shell'));
    expect(
      (await runner.run('write', {'file_path': '$work/main.c', 'content': 'x'})).text,
      contains('only their notes'),
    );
    final notes = await runner.run('write', {
      'file_path': '$work/.everyai/scratch/research/http.md',
      'content': '# notes',
    });
    expect(notes.isError, isFalse);
    expect((await runner.run('read', {'file_path': '$work/.env'})).text, contains('secrets'));
    expect(
      (await runner.run('web_fetch', {'url': 'https://example.com/x'})).text,
      contains('not on the research sites'),
    );
    // The .env value can't leave in a URL, even on an allowed site.
    final leak = await runner.run('web_fetch', {'url': 'https://github.com/search?q=supersecretvalue123'});
    expect(leak.text, contains('secret'));
    await shell.killAll();
  });

  test('a remote the agent added stays unpushable after a model switch and after reopening', () async {
    for (final args in [
      ['init', '-q'],
      ['remote', 'add', 'origin', 'https://github.com/me/repo.git'],
    ]) {
      expect((await Process.run('git', args, workingDirectory: work)).exitCode, 0);
    }
    File('$work/app.key').writeAsStringSync('SIGNING_TOKEN=Kx7remembered9value\n');
    gateway
      ..reply(
        calls: [
          ('bash', {'command': 'git remote add x https://example.invalid/r.git'}),
          ('read', {'file_path': 'app.key'}),
        ],
      )
      ..reply(text: 'Added.');
    final session = await harness.start(spec('add a remote', mode: AgentMode.bypass));
    await drive(session);
    final state =
        jsonDecode(File('${tmp.path}/data/everyai-sessions/${session.id}/state.json').readAsStringSync()) as Map;
    expect(state['push_targets'], isNot(contains('x')));

    /// Sends [text], answers with [calls] then [last], and returns the results of this turn.
    Future<List<ToolResult>> turn(HarnessSession s, List<(String, Map<String, Object?>)> calls, String last) async {
      gateway
        ..reply(calls: calls)
        ..reply(text: last);
      final results = <ToolResult>[];
      var live = false;
      final said = Completer<void>();
      final sub = s.events.listen((e) {
        if (e is ConnectionChange) live = true;
        if (live && e is ToolResult) results.add(e);
        if (live && e is StateChange && e.executionStatus == ExecutionStatus.waitingForConfirmation) {
          unawaited(s.respond(accept: true));
        }
        if (live && e is ChatMessage && !e.fromUser && e.text == last && !said.isCompleted) said.complete();
      });
      await s.send('go on');
      await said.future.timeout(const Duration(seconds: 20));
      await sub.cancel();
      return results;
    }

    await session.switchLlm(spec('x', mode: AgentMode.bypass));
    final afterSwitch = await turn(session, [
      ('bash', {'command': 'git push x main'}),
      ('bash', {'command': 'echo Kx7remembered9value'}),
    ], 'Switched.');
    expect(afterSwitch.first.text, contains("this repository's remotes"));
    expect(afterSwitch.last.text, isNot(contains('Kx7remembered9value')));
    await session.close();

    final reopened = await EveryAIHarness(
      dataDir: () async => '${tmp.path}/data',
      gatewayKey: () async => 'sk-test',
    ).attach(session.id);
    final afterReopen = await turn(reopened, [
      ('bash', {'command': 'git push x main'}),
    ], 'Reopened.');
    expect(afterReopen.single.text, contains("this repository's remotes"));
    await reopened.close();
  });

  test('the scrubber catches key shapes and secret-named env values, and lets ordinary URLs through', () {
    final s = Scrubber(env: {'OPENAI_API_KEY': 'abcd1234efgh', 'USER': 'xuckless', 'HOME': '/Users/x'});
    expect(s.leak('https://github.com/xuckless/repo/commit/${'a' * 40}'), isNull);
    expect(s.leak('https://x.io/?k=abcd1234efgh'), isNotNull);
    expect(s.leak('https://x.io/?k=abcd1234%65fgh'), isNotNull);
    expect(s.leak('q=ghp_${'A' * 30}'), 'a GitHub token');
    expect(s.leak('q=sk-${'a' * 30}'), 'an API key');
    expect(s.leak('AKIAABCDEFGHIJKLMNOP'), 'an AWS key');
    expect(hostAllowed('unix.stackexchange.com', ['*.stackexchange.com']), isTrue);
    expect(hostAllowed('evilgithub.com', ['github.com']), isFalse);
    expect(secretPath('/Users/x/.ssh/id_ed25519'), isTrue);
    expect(secretPath('/p/.env.example'), isFalse);
  });

  test('Bug fix: the harness runs the repro itself, refuses a fake fix, and verifies the real one', () async {
    File('$work/calc.sh').writeAsStringSync('echo \$((2 + 2 + 1))\n');
    const repro = 'test "\$(sh calc.sh)" = 4';
    gateway
      ..reply(
        calls: [
          ('bug_check', {'action': 'reproduced', 'command': 'true'}),
        ],
      )
      ..reply(
        calls: [
          ('bug_check', {'action': 'reproduced', 'command': repro}),
        ],
      )
      ..reply(
        calls: [
          ('bug_check', {'action': 'triage', 'kind': 'simple', 'why': 'An off-by-one in calc.sh.'}),
        ],
      )
      ..reply(
        calls: [
          ('write', {'file_path': '.everyai/scratch/plan.md', 'content': '# Remove the + 1'}),
        ],
      )
      ..reply(
        calls: [
          ('present_plan', {'plan': '# Remove the + 1'}),
        ],
      )
      ..reply(
        calls: [
          ('bug_check', {'action': 'verify'}),
        ],
      )
      ..reply(
        calls: [
          ('read', {'file_path': 'calc.sh'}),
        ],
      )
      ..reply(
        calls: [
          ('write', {'file_path': 'calc.sh', 'content': 'echo \$((2 + 2))\n'}),
        ],
      )
      ..reply(
        calls: [
          ('bug_check', {'action': 'verify'}),
        ],
      )
      ..reply(text: 'Fixed: calc.sh added one too many; the repro passes.');
    final session = await harness.start(
      SessionSpec(
        workingDir: work,
        model: 'anthropic/claude-sonnet-5.5',
        mode: AgentMode.fullAuto,
        llmBaseUrl: gateway.baseUrl,
        llmApiKey: 'sk-test',
        sessionTag: 'tag-bug',
        initialMessage: 'calc.sh prints 5 for 2 + 2',
        holdClientTools: true,
        bugCheck: true,
      ),
    );
    final events = await drive(session, answer: (c) => c.toolName == 'present_plan' ? planApprovedReason : null);
    final results = events.whereType<ToolResult>().map((r) => r.text).toList();
    expect(results[0], startsWith('Not reproduced'));
    expect(results[1], startsWith('Reproduced'));
    expect(results.where((r) => r.startsWith('Still failing')), hasLength(1), reason: 'verifying before the fix fails');
    expect(results.last, startsWith('Verified'));
    // No phases any more: the harness adds no notes of its own, and remembers the repro for later checks.
    expect(events.whereType<ChatMessage>().where((m) => m.fromUser), hasLength(1));
    final dir = '${tmp.path}/data/everyai-sessions/${session.id}';
    expect(jsonDecode(File('$dir/bug_check.json').readAsStringSync()), containsPair('repro_command', repro));
    final tools = (gateway.requests.first['tools']! as List).map((t) => ((t as Map)['function'] as Map)['name']);
    expect(tools, contains('bug_check'));
    // The approved plan is kept for compaction to re-inject.
    final state = jsonDecode(File('$dir/state.json').readAsStringSync());
    expect((state as Map)['approved_plan'], startsWith('# '));
  });

  test('Bug fix: a fix that edits the repro test is refused; adding a test beside it is fine', () async {
    File('$work/calc.sh').writeAsStringSync('echo \$((2 + 2 + 1))\n');
    File('$work/calc_test.sh').writeAsStringSync('test "\$(sh calc.sh)" = 4\n');
    gateway
      ..reply(
        calls: [
          ('bug_check', {'action': 'reproduced', 'command': 'sh calc_test.sh'}),
        ],
      )
      ..reply(
        calls: [
          ('bug_check', {'action': 'triage', 'kind': 'simple', 'why': 'Off by one.'}),
        ],
      )
      ..reply(
        calls: [
          ('present_plan', {'plan': '# Remove the + 1'}),
        ],
      )
      ..reply(
        calls: [
          ('read', {'file_path': 'calc_test.sh'}),
        ],
      )
      ..reply(
        calls: [
          ('write', {'file_path': 'calc_test.sh', 'content': 'exit 0\n'}),
        ],
      )
      ..reply(
        calls: [
          ('bug_check', {'action': 'verify'}),
        ],
      )
      ..reply(
        calls: [
          ('write', {'file_path': 'calc_test.sh', 'content': 'test "\$(sh calc.sh)" = 4\ntest 1 = 1\n'}),
        ],
      )
      ..reply(
        calls: [
          ('read', {'file_path': 'calc.sh'}),
        ],
      )
      ..reply(
        calls: [
          ('write', {'file_path': 'calc.sh', 'content': 'echo \$((2 + 2))\n'}),
        ],
      )
      ..reply(
        calls: [
          ('bug_check', {'action': 'verify'}),
        ],
      )
      ..reply(text: 'Fixed.');
    final session = await harness.start(
      SessionSpec(
        workingDir: work,
        model: 'anthropic/claude-sonnet-5.5',
        mode: AgentMode.fullAuto,
        llmBaseUrl: gateway.baseUrl,
        llmApiKey: 'sk-test',
        sessionTag: 'tag-bug2',
        initialMessage: 'calc.sh prints 5 for 2 + 2',
        holdClientTools: true,
        bugCheck: true,
      ),
    );
    final events = await drive(session, answer: (c) => c.toolName == 'present_plan' ? planApprovedReason : null);
    final results = events.whereType<ToolResult>().map((r) => r.text).toList();
    expect(results.first, startsWith('Reproduced'));
    expect(
      results.where((r) => r.startsWith('Not verified: the fix changed what reproduces the bug (calc_test.sh)')),
      hasLength(1),
    );
    expect(results.last, startsWith('Verified'));
  });

  test('the third identical call in a row is not run; the memory tool is offered', () async {
    File('$work/a.txt').writeAsStringSync('a');
    for (var i = 0; i < 3; i++) {
      gateway.reply(
        calls: [
          ('read', {'file_path': 'a.txt'}),
        ],
      );
    }
    gateway.reply(text: 'Done.');
    final session = await harness.start(
      SessionSpec(
        workingDir: work,
        model: 'anthropic/claude-sonnet-5.5',
        mode: AgentMode.fullAuto,
        llmBaseUrl: gateway.baseUrl,
        llmApiKey: 'sk-test',
        sessionTag: 'tag-loop',
        initialMessage: 'read it',
        holdClientTools: true,
      ),
    );
    final events = await drive(session);
    final results = events.whereType<ToolResult>().map((r) => r.text).toList();
    expect(results, hasLength(3));
    expect(results.last, startsWith('Not run: this is the 3rd identical read call'));
    final tools = (gateway.requests.first['tools']! as List).map((t) => ((t as Map)['function'] as Map)['name']);
    expect(tools, contains('memory'));
    expect(tools, isNot(contains('bug_check')), reason: 'only Bug fix agents get it');
  });

  group('per-call approvals', () {
    /// Runs [session] until it settles; at the first approval [decide] answers
    /// the waiting calls (action ids, in order).
    Future<List<HarnessEvent>> settle(
      HarnessSession session,
      Future<void> Function(List<ActionCall> calls) decide,
    ) async {
      final events = <HarnessEvent>[];
      final open = <ActionCall>[];
      final done = Completer<void>();
      var asked = false;
      final sub = session.events.listen((e) async {
        events.add(e);
        if (e is ActionCall) open.add(e);
        if (e is ToolResult) open.removeWhere((c) => c.id == e.actionId);
        if (e is StateChange && e.executionStatus == ExecutionStatus.waitingForConfirmation && !asked) {
          asked = true;
          await decide([...open]);
        }
        if (e is StateChange &&
            const {
              ExecutionStatus.finished,
              ExecutionStatus.error,
              ExecutionStatus.paused,
            }.contains(e.executionStatus)) {
          if (!done.isCompleted) done.complete();
        }
      });
      await done.future.timeout(const Duration(seconds: 20));
      await sub.cancel();
      return events;
    }

    test('allowing one call and refusing another runs the one and carries on', () async {
      gateway
        ..reply(
          calls: [
            ('write', {'file_path': 'a.txt', 'content': 'a\n'}),
            ('write', {'file_path': 'b.txt', 'content': 'b\n'}),
          ],
        )
        ..reply(text: 'Wrote a only.');
      final session = await harness.start(spec('write two files', mode: AgentMode.ask));
      expect(session, isA<PerCallApprovals>());
      final events = await settle(session, (calls) async {
        expect(calls, hasLength(2));
        await session.respond(accept: false, reason: 'Not b.', callIds: [calls[1].id]);
        await session.respond(accept: true, callIds: [calls[0].id]);
      });
      expect(File('$work/a.txt').existsSync(), isTrue);
      expect(File('$work/b.txt').existsSync(), isFalse);
      expect(events.whereType<StateChange>().last.executionStatus, ExecutionStatus.finished);
      final rejected = events.whereType<ToolResult>().where((r) => r.outcome == ToolOutcome.rejected);
      expect(rejected, hasLength(1));
      final last = gateway.requests.last['messages']! as List<Object?>;
      final tools = last.where((m) => (m! as Map)['role'] == 'tool').map((m) => (m! as Map)['content']).toList();
      expect(tools, contains('Not b.'));
      expect(tools, hasLength(2));
    });

    test('Deny all parks the run', () async {
      gateway.reply(
        calls: [
          ('write', {'file_path': 'a.txt', 'content': 'a\n'}),
          ('bash', {'command': 'touch c.txt'}),
        ],
      );
      final session = await harness.start(spec('two things', mode: AgentMode.ask));
      final events = await settle(session, (_) => session.respond(accept: false, reason: 'No.'));
      expect(events.whereType<StateChange>().last.executionStatus, ExecutionStatus.paused);
      expect(File('$work/a.txt').existsSync(), isFalse);
      expect(gateway.requests, hasLength(1), reason: 'no model call after Deny all');
    });
  });
}
