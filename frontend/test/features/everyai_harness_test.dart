import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/everyai/everyai_harness_io.dart';
import 'package:every_ai/features/code/harness/everyai/llm.dart';
import 'package:every_ai/features/code/harness/everyai/prompt_io.dart';
import 'package:every_ai/features/code/harness/everyai/shell_io.dart';
import 'package:every_ai/features/code/harness/everyai/tools_io.dart';
import 'package:every_ai/features/code/harness/harness.dart';
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

  static Future<FakeGateway> start() async => FakeGateway._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  String get baseUrl => 'http://127.0.0.1:${_server.port}/v1';

  /// A reply with [text] and these tool calls (name, arguments).
  void reply({String text = '', List<(String, Map<String, Object?>)> calls = const []}) => replies.add({
    'text': text,
    'calls': [for (final (name, args) in calls) (name, jsonEncode(args))],
  });

  Future<void> _handle(HttpRequest req) async {
    final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, Object?>;
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
    final next = replies.isEmpty ? {'text': 'Done.', 'calls': const <(String, String)>[]} : replies.removeAt(0);
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

  SessionSpec spec(String first, {AgentMode mode = AgentMode.fullAuto}) => SessionSpec(
    workingDir: work,
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

  test('a fork starts from the parent\'s exact history, so the cached prefix is shared', () async {
    gateway
      ..reply(
        calls: [
          ('read', {'file_path': 'notes.txt'}),
        ],
      )
      ..reply(text: 'Read it.');
    File('$work/notes.txt').writeAsStringSync('one\n');
    final parent = await harness.start(spec('look at notes'));
    await drive(parent);
    final parentLast = gateway.requests.last['messages']! as List<Object?>;

    gateway.reply(text: 'Forked result.');
    final child = await harness.fork(parent.id, spec('Now count the lines.'));
    await drive(child);
    final forked = gateway.requests.last['messages']! as List<Object?>;
    // Everything the parent sent last, then its reply and the fork's directive.
    expect(jsonEncode(forked.take(parentLast.length).toList()), jsonEncode(parentLast));
    expect((forked.last! as Map)['content'], 'Now count the lines.');
  });

  test('a fork keeps the parent\'s tools but cannot ask the user or start subagents', () async {
    gateway.reply(text: 'Parent done.');
    final parent = await harness.start(spec('hi'));
    await drive(parent);
    gateway
      ..reply(
        calls: [
          (askUserQuestionTool, {'questions': <Object?>[]}),
        ],
      )
      ..reply(text: 'Report.');
    final child = await harness.fork(parent.id, spec('do a thing'));
    final events = await drive(child);
    final refused = events.whereType<ToolResult>().single;
    expect(refused.text, contains('a fork cannot use ask_user_question'));
    // Same tool list as the parent, so the cached prefix holds.
    expect(jsonEncode(gateway.requests.last['tools']), jsonEncode(gateway.requests.first['tools']));
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

  test('monitor wakes when a background shell prints the line', () async {
    final shell = SessionShell(root: work, sessionTag: 't', scratchDir: '${tmp.path}/sh');
    final runner = ToolRunner(
      root: work,
      shell: shell,
      gateway: GatewayClient(baseUrl: 'http://127.0.0.1:9/v1', apiKey: ''),
      sessionTag: 't',
    );
    final started = await runner.run('bash', {
      'command': 'sleep 0.3; echo server ready; sleep 30',
      'run_in_background': true,
    });
    final id = started.observation['shell_id']! as String;
    final watch = Stopwatch()..start();
    final out = await runner.run('monitor', {'shell_id': id, 'until': 'ready', 'timeout_ms': 20000});
    expect(out.text, contains('Matched: server ready'));
    expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    await shell.killAll();
  });

  test('cd carries over between commands and a timeout kills the command', () async {
    Directory('$work/sub').createSync();
    final shell = SessionShell(root: work, sessionTag: 't', scratchDir: '${tmp.path}/sh');
    await shell.run('cd sub', timeout: const Duration(seconds: 10));
    final pwd = await shell.run('pwd', timeout: const Duration(seconds: 10));
    expect(pwd.output.trim(), endsWith('/sub'));
    final slow = await shell.run('sleep 20', timeout: const Duration(seconds: 1));
    expect(slow.timedOut, isTrue);
  });

  group('applyEdit', () {
    test('replaces an exact, unique match', () {
      final r = applyEdit('a\nb\nc\n', 'b\n', 'B\n');
      expect(r.text, 'a\nB\nc\n');
    });

    test('refuses an ambiguous match unless replace_all', () {
      expect(applyEdit('x\nx\n', 'x', 'y').error, contains('2 places'));
      expect(applyEdit('x\nx\n', 'x', 'y', replaceAll: true).text, 'y\ny\n');
    });

    test('matches lines whose indentation is off', () {
      final r = applyEdit('def f():\n    return 1\n', 'def f():\n  return 1', 'def f():\n    return 2');
      expect(r.text, 'def f():\n    return 2\n');
    });
  });

  test('the environment block warns when pip and python3 are different Pythons', () {
    final block = formatEnvironment(
      workingDir: '/p',
      shell: '/bin/zsh',
      today: DateTime(2026, 10, 30),
      facts: {
        'which.python3': '/opt/homebrew/bin/python3',
        'which.pip': '/Users/a/Library/Python/3.9/bin/pip',
        'python3.version': '3.14.0 /opt/homebrew/bin/python3',
        'python3.pip': 'pip 25.2 from /opt/homebrew/lib/python3.14/site-packages/pip (python 3.14)',
        'pip.version': 'pip 21.2 from /Users/a/Library/Python/3.9/lib/python/site-packages/pip (python 3.9)',
      },
    );
    expect(block, contains('`pip` installs into Python 3.9 but `python3` is Python 3.14'));
    expect(block, contains('python3 -m pip'));
  });
}
