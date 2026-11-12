import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:every_ai/core/process/supervisor.dart' show Ended, KillOutcome;
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/permissions.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/drivers/acp/acp_driver.dart';
import 'package:every_ai/features/code/drivers/acp/acp_files.dart';
import 'package:every_ai/features/code/drivers/briefing/briefing_types.dart';
import 'package:every_ai/features/code/drivers/driver_policy.dart';
import 'package:every_ai/features/code/drivers/json_rpc.dart';
import 'package:every_ai/features/code/drivers/usage_limit.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/host/host.dart';
import 'package:every_ai/features/questions/domain/questions.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/replay_transport.dart';

const _fixtures = 'test/fixtures/drivers';

typedef _Spawn = ({String executable, List<String> args, String cwd, String logPath, Map<String, String> env});

/// Drivers on recorded (or derived) agents: each start of the agent plays
/// the next script.
final class _Rig {
  _Rig(this.root, this.scripts);

  final String root;
  final List<String> scripts;
  final spawns = <_Spawn>[];
  final channels = <ReplayChannel>[];

  String get dataDir => '$root/data';
  String get work => '$root/work';

  AcpDriver driver(
    String id,
    String command, {
    List<String> args = const [],
    Duration? initTimeout,
    Future<String?> Function(String command)? which,
    AcpConnect? connect,
    AcpConnect? ttyConnect,
    Map<String, String> loginEnv = const {},
  }) => AcpDriver(
    id: id,
    label: switch (command) {
      'gemini' => 'Gemini CLI',
      'opencode' => 'OpenCode',
      'cursor-agent' => 'Cursor CLI',
      'grok' => 'Grok Build',
      _ => command,
    },
    command: command,
    args: args,
    which: which ?? (c) async => '/usr/local/bin/$c',
    dataDir: () async => dataDir,
    initTimeout: initTimeout ?? const Duration(seconds: 60),
    replayQuiet: Duration.zero,
    loginEnv: () async => loginEnv,
    ttyConnect: ttyConnect,
    connect: connect ?? replay,
  );

  /// Starts the agent on the next script.
  Future<LineChannel> replay({
    required String executable,
    required List<String> args,
    required String cwd,
    required String sessionTag,
    required String logPath,
    required Map<String, String> env,
  }) async {
    spawns.add((executable: executable, args: args, cwd: cwd, logPath: logPath, env: env));
    final c = ReplayChannel.file('$_fixtures/${scripts.removeAt(0)}');
    channels.add(c);
    return c;
  }

  SessionSpec spec({
    AgentMode mode = AgentMode.ask,
    String model = 'm',
    String? effort,
    DriverBriefing? briefing,
    String? initial,
  }) => SessionSpec(
    workingDir: work,
    model: model,
    effort: effort,
    mode: mode,
    llmBaseUrl: 'http://127.0.0.1:9/v1',
    llmApiKey: 'sk-test',
    sessionTag: 's1',
    briefing: briefing,
    initialMessage: initial,
  );

  void expectPlayed() {
    for (final c in channels) {
      c.expectFinished();
    }
  }
}

/// Collects a session's events.
final class _Seen {
  _Seen(HarnessSession s) {
    s.events.listen(all.add);
  }

  final all = <HarnessEvent>[];

  List<ExecutionStatus> get statuses => [for (final e in all.whereType<StateChange>()) e.executionStatus];
  ExecutionStatus? get status => statuses.lastOrNull;
  List<ActionCall> get calls => all.whereType<ActionCall>().toList();
  List<ToolResult> get results => all.whereType<ToolResult>().toList();
  List<String> get notices => [for (final e in all.whereType<ConversationFailure>()) e.message];
  List<ChatMessage> get messages => all.whereType<ChatMessage>().toList();

  Future<void> until(bool Function() cond) async {
    for (var i = 0; i < 100 && !cond(); i++) {
      await pumpEventQueue();
    }
    expect(cond(), isTrue, reason: 'events: ${all.map((e) => e.raw['kind'] ?? e.runtimeType).toList()}');
  }

  Future<void> untilStatus(ExecutionStatus s) => until(() => status == s);
}

/// The text of each prompt sent on [c].
List<String> _prompts(ReplayChannel c) => [
  for (final m in c.sent)
    if (m['method'] == 'session/prompt') (((m['params']! as Map)['prompt']! as List).first as Map)['text']! as String,
];

/// A stored conversation `conv` for [r], as the driver leaves one.
Directory _stored(
  _Rig r,
  String conv,
  String acpSessionId, {
  List<String> mcp = const [],
  List<Map<String, Object?>> events = const [],
}) {
  final dir = Directory('${r.dataDir}/acp-sessions/$conv')..createSync(recursive: true);
  File('${dir.path}/meta.json').writeAsStringSync(
    jsonEncode({'acpSessionId': acpSessionId, 'cwd': r.work, 'sessionTag': 's1', 'mode': 'ask', 'mcpServers': mcp}),
  );
  if (events.isNotEmpty) File('${dir.path}/events.jsonl').writeAsStringSync('${events.map(jsonEncode).join('\n')}\n');
  return dir;
}

/// The app's side of the MCP host for a session: records each call and
/// answers it when the test says.
final class _Host implements HostTools {
  final calls = <HostCall>[];
  final _replies = <Completer<HostResult>>[];

  @override
  Future<HostResult> call(HostCall call) {
    calls.add(call);
    final c = Completer<HostResult>();
    _replies.add(c);
    return c.future;
  }

  void answer(String text, {bool isError = false}) => _replies.removeAt(0).complete((text: text, isError: isError));
}

DriverBriefing _cursorBrief(HostTools host) =>
    DriverBriefing(mcpUrl: 'http://127.0.0.1:7777/mcp', mcpToken: 'tok-cursor', host: host);

/// Our reply to the agent's request [id] on [c].
Object? _replyTo(ReplayChannel c, String id) =>
    c.sent.singleWhere((m) => m['id'] == id && m['method'] == null)['result'];

Transcript _transcript(List<HarnessEvent> events) {
  final b = TranscriptBuilder();
  events.forEach(b.add);
  return b.snapshot;
}

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('acp-driver');
    Directory('${tmp.path}/work').createSync();
  });
  tearDown(() => tmp.delete(recursive: true));

  _Rig rig(List<String> scripts) => _Rig(tmp.path, scripts);

  group('OpenCode (recorded)', () {
    test('the handshake: our initialize and session/new, the metadata, the models, Plan pinned', () async {
      final r = rig(['opencode/handshake.jsonl']);
      final d = r.driver('acp:opencode', 'opencode');
      final s = await d.start(r.spec(mode: AgentMode.plan));
      await r.channels.single.finished;
      r.expectPlayed();
      final spawn = r.spawns.single;
      expect((spawn.executable, spawn.cwd), ('/usr/local/bin/opencode', r.work));
      expect(spawn.args, ['acp']);
      // No permission rules of ours: OpenCode's agents keep their own.
      expect(spawn.env.containsKey('OPENCODE_CONFIG_CONTENT'), isFalse);
      final meta =
          jsonDecode(File('${r.dataDir}/acp-sessions/${s.id}/meta.json').readAsStringSync()) as Map<String, Object?>;
      expect(meta, {
        'acpSessionId': 'ses_e5adb7e4effeCCHUFq6T8P7fJY',
        'cwd': r.work,
        'sessionTag': 's1',
        'mode': 'plan',
        'mcpServers': <Object?>[],
        // The recorded available_commands_update, kept for a reopen.
        'commands': [
          {'name': 'init', 'description': 'guided AGENTS.md setup'},
          {'name': 'review', 'description': 'review changes [commit|branch|pr], defaults to uncommitted'},
          {'name': 'compact', 'description': 'Compact the session'},
        ],
      });
      final models = await d.models();
      expect(models, hasLength(4));
      final def = models.singleWhere((m) => m.isDefault);
      expect(def.id, 'opencode/crouton-alpha-free');
      expect(def.efforts, ['minimal', 'low', 'medium', 'high', 'xhigh', 'max']);
      expect(await d.statuses([s.id, 'nope']), {s.id: ExecutionStatus.idle});
      await s.close();
    });

    test('a reopened conversation shows its journal at once; the agent starts and loads on the next message', () async {
      final r = rig(['opencode/load.jsonl']);
      final first = r.driver('acp:opencode', 'opencode');
      final dir = Directory('${r.dataDir}/acp-sessions/conv-1')..createSync(recursive: true);
      File('${dir.path}/meta.json').writeAsStringSync(
        jsonEncode({
          'acpSessionId': 'ses_e5ad81ff1ffeGaamwMA9ctbrrE',
          'cwd': r.work,
          'sessionTag': 's1',
          'mode': 'ask',
        }),
      );
      File('${dir.path}/events.jsonl').writeAsStringSync(
        '${[
          {
            'kind': 'MessageEvent',
            'id': 'old-u1',
            'source': 'user',
            'llm_message': {'role': 'user', 'content': 'Earlier'},
          },
          {'kind': 'ConversationStateUpdateEvent', 'id': 'old-s1', 'key': 'execution_status', 'value': 'running'},
        ].map(jsonEncode).join('\n')}\n',
      );
      expect(await first.statuses(['conv-1']), {'conv-1': ExecutionStatus.idle});
      final s = await first.attach('conv-1');
      final seen = _Seen(s);
      await pumpEventQueue();
      expect(r.spawns, isEmpty);
      expect(seen.messages.single.text, 'Earlier');
      // A run cut off by the app closing ends as stopped.
      expect(seen.status, ExecutionStatus.paused);
      await s.send('Reply with just the word OK.');
      await seen.untilStatus(ExecutionStatus.error);
      r.expectPlayed();
      // The agent's replay of the old user message is dropped: only ours shows.
      expect([for (final m in seen.messages) m.text], ['Earlier', 'Reply with just the word OK.']);
      final journal = File('${dir.path}/events.jsonl').readAsLinesSync();
      expect(journal.length, greaterThan(2));
      await s.close();
    });

    test('a conversation the agent no longer has starts fresh, with a notice', () async {
      final r = rig(['opencode/load_missing.jsonl']);
      final d = r.driver('acp:opencode', 'opencode');
      final dir = Directory('${r.dataDir}/acp-sessions/conv-3')..createSync(recursive: true);
      File('${dir.path}/meta.json')
          .writeAsStringSync(jsonEncode({'acpSessionId': 'ses_nonexistent', 'cwd': r.work, 'sessionTag': 's1'}));
      final s = await d.attach('conv-3');
      final seen = _Seen(s);
      await s.send('Reply with just the word OK.');
      await seen.untilStatus(ExecutionStatus.error);
      r.expectPlayed();
      expect(
        seen.notices.first,
        "OpenCode couldn't reopen its conversation, so it starts fresh. The history above is for you only.",
      );
      final meta = jsonDecode(File('${dir.path}/meta.json').readAsStringSync()) as Map<String, Object?>;
      expect(meta['acpSessionId'], 'ses_e5adb7e4effeCCHUFq6T8P7fJY');
      await s.close();
    });
  });

  group('review fixes', () {
    test('attachBriefed: the reopened agent starts with the new token, not the old one, and none is stored', () async {
      final r = rig(['opencode/usage_reopen.jsonl']);
      _stored(r, 'o1', 'ses_e5ad81ff1ffeGaamwMA9ctbrrE', mcp: ['github']);
      final d = r.driver('acp:opencode', 'opencode');
      expect(d, isA<AttachesBriefed>());
      final s = await (d as AttachesBriefed).attachBriefed(
        'o1',
        DriverBriefing(
          mcpUrl: 'http://127.0.0.1:7001/mcp',
          mcpToken: 'tok-new',
          skillDir: '${tmp.path}/b/briefing/skills',
          sessionSkill: 'Session text.',
        ),
      );
      final seen = _Seen(s);
      await s.send('Hi');
      await seen.untilStatus(ExecutionStatus.finished);
      r.expectPlayed();
      final env = r.spawns.single.env;
      expect(env[tokenEnvVar], 'tok-new');
      expect(env['OPENCODE_CONFIG_CONTENT'], contains('127.0.0.1:7001'));
      expect(r.spawns.single.args.join(' '), isNot(contains('tok-new')));
      await s.close();
      for (final f in Directory(r.dataDir).listSync(recursive: true).whereType<File>()) {
        expect(f.readAsStringSync(), isNot(contains('tok-new')), reason: f.path);
      }
    });

    test('two writers of one JSON file both land', () async {
      final path = '${tmp.path}/data/models.json';
      await Future.wait([
        writeJsonFile(path, {'a': 1}),
        writeJsonFile(path, {'a': 2}),
      ]);
      expect((await readJsonFile(path))?['a'], anyOf(1, 2));
    });
  });

  group('Gemini CLI (derived from its source)', () {
    test('a turn: its default mode, a shell call to approve once, its output, the reply', () async {
      final r = rig(['gemini/turn.jsonl']);
      final d = r.driver('gemini', 'gemini', args: const ['--acp']);
      final s = await d.start(r.spec(model: 'gemini-2.5-flash'));
      final seen = _Seen(s);
      expect(r.spawns.single.args, ['--acp']);
      expect([for (final m in await d.models()) m.id], ['auto-gemini-2.5', 'gemini-2.5-pro', 'gemini-2.5-flash']);
      await s.send('List the files.');
      await seen.untilStatus(ExecutionStatus.waitingForConfirmation);
      final call = seen.calls.single;
      expect((call.actionKind, call.summary), ('AcpExecuteAction', 'ls -la [current working directory] (List files)'));
      expect(autoDecidable(call), isFalse);
      // The reply streamed so far was flushed before the call.
      final before = seen.messages.last;
      expect((before.text, before.reasoning), ("I'll list them.", 'Looking around.'));
      await s.respond(accept: true, callIds: [call.id]);
      await seen.untilStatus(ExecutionStatus.finished);
      r.expectPlayed();
      final answer = r.channels.single.sent.firstWhere((m) => m['id'] == 0);
      expect(answer['result'], {
        'outcome': {'outcome': 'selected', 'optionId': 'proceed_once'},
      });
      expect((seen.results.single.actionId, seen.results.single.text), (call.id, 'a.txt\nb.txt'));
      expect(seen.messages.last.text, 'Two files. Done.');
      expect(seen.all.whereType<StreamDelta>().length, 4);
      await s.close();
    });

    test('one call refused with a reason: the run goes on, and the reason opens the next prompt', () async {
      final r = rig(['gemini/deny_one.jsonl']);
      final s = await r.driver('gemini', 'gemini').start(r.spec());
      final seen = _Seen(s);
      await s.send('Clean up.');
      await seen.untilStatus(ExecutionStatus.waitingForConfirmation);
      await s.respond(
        accept: false,
        reason: denialMessage(DenialKind.denied, reason: 'Not now.'),
        callIds: [seen.calls.single.id],
      );
      await seen.untilStatus(ExecutionStatus.finished);
      expect(seen.statuses, contains(ExecutionStatus.running));
      expect((seen.results.single.outcome, seen.results.length), (ToolOutcome.rejected, 1));
      await s.resume();
      await s.send('What next?');
      await r.channels.single.finished;
      await seen.until(() => seen.statuses.where((x) => x == ExecutionStatus.finished).length == 2);
      r.expectPlayed();
      await s.close();
    });

    test('interrupt answers what waits as cancelled and closes the open calls', () async {
      final r = rig(['gemini/interrupt.jsonl']);
      final s = await r.driver('gemini', 'gemini').start(r.spec());
      final seen = _Seen(s);
      await s.send('Look and clean.');
      await seen.untilStatus(ExecutionStatus.waitingForConfirmation);
      expect(seen.calls.map((c) => c.actionKind), ['ReadFileAction', 'AcpExecuteAction']);
      await s.interrupt();
      await seen.untilStatus(ExecutionStatus.paused);
      r.expectPlayed();
      expect(
        [for (final x in seen.results) (x.actionId, x.text)],
        [('tc-run_shell_command-3', 'Cancelled.'), ('tc-read_file-1', 'Cancelled.')],
      );
      await s.close();
    });

    test('a spent quota ends the turn as a usage limit', () async {
      final r = rig(['gemini/quota.jsonl']);
      final s = await r.driver('gemini', 'gemini').start(r.spec());
      final seen = _Seen(s);
      await s.send('Go on.');
      await seen.untilStatus(ExecutionStatus.error);
      r.expectPlayed();
      final limit = seen.all.map(usageLimitOf).nonNulls.single;
      expect(limit.message, startsWith('Gemini CLI: You have exhausted your capacity'));
      expect(limit.resetsAt, isNotNull);
      await s.close();
    });

    test('a message sent during a turn goes out after it', () async {
      final r = rig(['gemini/serial.jsonl']);
      final s = await r.driver('gemini', 'gemini').start(r.spec());
      final seen = _Seen(s);
      await s.send('one');
      await seen.untilStatus(ExecutionStatus.waitingForConfirmation);
      await s.send('two');
      await pumpEventQueue();
      expect(_prompts(r.channels.single), ['one']);
      await s.respond(accept: true);
      await r.channels.single.finished;
      await seen.until(() => seen.statuses.where((x) => x == ExecutionStatus.finished).length == 2);
      r.expectPlayed();
      expect(_prompts(r.channels.single), ['one', 'two']);
      await s.close();
    });
  });

  test('Gemini counts as signed in with an API key; a cached personal Google sign-in no longer does', () async {
    final home = tmp.path;
    expect(await geminiSignedIn(home: home, env: const {'GEMINI_API_KEY': 'k'}), isTrue);
    expect(await geminiSignedIn(home: home, env: const {}), isFalse);
    Directory('$home/.gemini').createSync();
    File('$home/.gemini/settings.json').writeAsStringSync('{"security":{"auth":{"selectedType":"oauth-personal"}}}');
    expect(await geminiSignedIn(home: home, env: const {}), isFalse);
    File('$home/.gemini/oauth_creds.json').writeAsStringSync('{}');
    expect(await geminiSignedIn(home: home, env: const {}), isFalse);
    // With a Cloud project it may be a Code Assist licence: unknown.
    expect(await geminiSignedIn(home: home, env: const {'GOOGLE_CLOUD_PROJECT': 'p'}), isNull);
    expect(await geminiSignedIn(home: home, env: const {'GOOGLE_CLOUD_PROJECT_ID': 'p'}), isNull);
    // Gemini CLI also loads ~/.gemini/.env and ~/.env, as its auth docs suggest.
    File('$home/.gemini/.env').writeAsStringSync('# licence\nGOOGLE_CLOUD_PROJECT=my-proj\n');
    expect(await geminiSignedIn(home: home, env: const {}), isNull);
    File('$home/.gemini/.env').writeAsStringSync('GOOGLE_CLOUD_PROJECT=""\n');
    expect(await geminiSignedIn(home: home, env: const {}), isFalse);
    File('$home/.env').writeAsStringSync('export GEMINI_API_KEY=k\n');
    expect(await geminiSignedIn(home: home, env: const {}), isTrue);
    File('$home/.env').deleteSync();
    File('$home/.gemini/settings.json').writeAsStringSync('{"security":{"auth":{"selectedType":"vertex-ai"}}}');
    expect(await geminiSignedIn(home: home, env: const {}), isNull);
  });

  group('other ACP agents', () {
    test("EveryAI's own tools pass without a card, except check and bug_check, which wait for the user", () async {
      final r = rig(['acp/host_run_tools.jsonl']);
      final s = await r.driver('acp:dsh', 'dsh').start(r.spec());
      final seen = _Seen(s);
      await s.send('go');
      await seen.untilStatus(ExecutionStatus.waitingForConfirmation);
      // memory was answered at once; check waits for the card.
      expect(_replyTo(r.channels.single, 'p1'), {
        'outcome': {'outcome': 'selected', 'optionId': 'yes'},
      });
      expect(r.channels.single.sent.where((m) => m['id'] == 'p2'), isEmpty);
      final check = _transcript(seen.all).pending.singleWhere((c) => hostToolOf(c) == 'check');
      await s.respond(accept: true, callIds: [check.id]);
      await seen.untilStatus(ExecutionStatus.finished);
      r.expectPlayed();
      await s.close();
    });

    test("Always allow on the card is the agent's own allow_always; without one, allowed once with a notice", () async {
      final r = rig(['acp/allow_always.jsonl']);
      final d = r.driver('acp:dsh', 'dsh');
      expect(d.remembers, NativeRemember.agentAlways);
      final s = await d.start(r.spec());
      final seen = _Seen(s);
      await s.send('go');
      for (final title in ['Deploy', 'Publish']) {
        await seen.until(() => _transcript(seen.all).pending.any((c) => c.summary == title));
        final call = _transcript(seen.all).pending.singleWhere((c) => c.summary == title);
        await (s as AllowsRemembered).allowRemembered(NativeGrant.always, callIds: [call.id]);
      }
      await seen.untilStatus(ExecutionStatus.finished);
      r.expectPlayed();
      expect(seen.notices, ['dsh offered no "always" for "Publish", so it was allowed once.']);
      await s.close();
    });
  });

  group('Cursor CLI (derived from its ACP doc)', () {
    Future<(_Rig, HarnessSession, _Seen, _Host)> asking(String script) async {
      final r = rig([script]);
      final host = _Host();
      final s = await r.driver('cursor', 'cursor-agent').start(r.spec(briefing: _cursorBrief(host)));
      final seen = _Seen(s);
      await s.send('go');
      await seen.until(() => host.calls.isNotEmpty);
      return (r, s, seen, host);
    }

    test('cursor/ask_question is our question card; the picks go back as option ids', () async {
      final (r, s, seen, host) = await asking('cursor/ask.jsonl');
      final row = seen.calls.single;
      expect(
        (row.toolName, row.actionKind, hostToolOf(row)),
        ('everyai__ask_user_question', 'MCPToolAction', askUserQuestionTool),
      );
      final call = host.calls.single;
      expect((call.name, call.id), (askUserQuestionTool, row.id));
      expect(call.args, {
        'questions': [
          {
            'question': 'Which database?',
            'header': 'Setup',
            'multi_select': false,
            'options': [
              {'label': 'Postgres', 'description': ''},
              {'label': 'SQLite', 'description': ''},
            ],
          },
          {
            'question': 'Which extras?',
            'header': '',
            'multi_select': true,
            'options': [
              {'label': 'Auth', 'description': ''},
              {'label': 'Billing', 'description': ''},
              {'label': 'Search', 'description': ''},
            ],
          },
        ],
      });
      for (final e in call.args.entries) {
        expect(row.action[e.key], e.value);
      }
      // Waiting on a card isn't waiting on an approval.
      expect(seen.status, ExecutionStatus.running);
      final questions = Question.listFrom(call.args);
      final answers = [
        const QuestionAnswer(selected: {0}),
        const QuestionAnswer(selected: {0, 2}),
      ];
      host.answer(answersReason(questions, answers));
      await seen.untilStatus(ExecutionStatus.finished);
      r.expectPlayed();
      expect(_replyTo(r.channels.single, 'q1'), {
        'outcome': {
          'outcome': 'answered',
          'answers': [
            {
              'questionId': 'db',
              'selectedOptionIds': ['pg'],
            },
            {
              'questionId': 'extras',
              'selectedOptionIds': ['auth', 'search'],
            },
          ],
        },
      });
      // Cursor's own tool_call for the same id added no second row.
      expect(seen.calls, hasLength(1));
      final card = _transcript(seen.all).items.whereType<QuestionItem>().single;
      expect(card.answers, answers);
      await s.close();
    });

    test('cursor/create_plan is our plan card: approved is accepted, changes are rejected with the words', () async {
      final revise = '$planRevisionLead Use a stateful widget.';
      for (final (text, want) in [
        (
          planApprovedReason,
          {
            'outcome': {'outcome': 'accepted'},
          },
        ),
        (
          revise,
          {
            'outcome': {'outcome': 'rejected', 'reason': revise},
          },
        ),
      ]) {
        final (r, s, seen, host) = await asking('cursor/plan.jsonl');
        final row = seen.calls.single;
        expect((row.toolName, hostToolOf(row)), ('everyai__present_plan', presentPlanTool));
        expect(host.calls.single.args, {
          'title': 'Add a counter',
          'summary': 'A counter with tests.',
          'steps': [
            {'title': 'Write the widget'},
            {'title': 'Add a test'},
          ],
          'body': '## Steps\n\nBuild it, then test it.',
        });
        final plan = _transcript(seen.all).items.whereType<PlanProposal>().single;
        expect(plan.markdown, contains('Build it, then test it.'));
        expect(plan.steps.map((st) => st.title), ['Write the widget', 'Add a test']);
        host.answer(text);
        await seen.untilStatus(ExecutionStatus.finished);
        r.expectPlayed();
        expect(_replyTo(r.channels.single, 'p1'), want);
        final settled = _transcript(seen.all).items.whereType<PlanProposal>().single;
        expect(settled.verdict, text == planApprovedReason ? PlanVerdict.approved : PlanVerdict.revised);
        await s.close();
      }
    });

    test('Stop while a plan waits: the card is given up, Cursor gets cancelled, the row is Cancelled', () async {
      final (r, s, seen, host) = await asking('cursor/plan_stop.jsonl');
      await s.interrupt();
      expect(await host.calls.single.ended, HostEnd.cancelled);
      await seen.untilStatus(ExecutionStatus.paused);
      r.expectPlayed();
      expect(seen.results.single.text, 'Cancelled.');
      expect(seen.results.single.actionId, seen.calls.single.id);
      await s.close();
    });

    test('closing the session, or the agent exiting, gives up a waiting card', () async {
      final (_, s, _, host) = await asking('cursor/plan.jsonl');
      await s.close();
      expect(await host.calls.single.ended, HostEnd.sessionClosed);

      final (_, s2, seen2, host2) = await asking('cursor/ask_eof.jsonl');
      expect(await host2.calls.single.ended, HostEnd.clientGone);
      await seen2.until(() => seen2.results.isNotEmpty);
      expect(seen2.results.single.text, 'Cancelled.');
      await s2.close();
    });
  });

  group('Grok Build (derived from T3 Code)', () {
    test('initialize says it is an extension client; Stop sends Ctrl+C in _meta', () async {
      final r = rig(['grok/cancel.jsonl']);
      final s = await r.driver('grok', 'grok').start(r.spec());
      final seen = _Seen(s);
      expect(r.spawns.single.args, ['--no-auto-update', 'agent', 'stdio']);
      await s.send('go');
      await seen.untilStatus(ExecutionStatus.running);
      await s.interrupt();
      await seen.untilStatus(ExecutionStatus.paused);
      r.expectPlayed();
      await s.close();
    });

    test('two sessions that exit for want of a terminal at once: both start again under one', () async {
      final r = rig(['grok/handshake.jsonl', 'grok/handshake.jsonl']);
      final both = Completer<void>();
      var piped = 0;
      final d = r.driver(
        'grok',
        'grok',
        connect:
            ({
              required String executable,
              required List<String> args,
              required String cwd,
              required String sessionTag,
              required String logPath,
              required Map<String, String> env,
            }) async {
              if (++piped == 2) both.complete();
              await both.future;
              return _NoTty();
            },
        ttyConnect: r.replay,
      );
      final sessions = await Future.wait([d.start(r.spec()), d.start(r.spec())]);
      for (final s in sessions) {
        await s.close();
      }
      r.expectPlayed();
      expect((piped, r.channels.length), (2, 2));
    });
  });

  group('native modes', () {
    Future<NativeModeSet> modesOf(HarnessSession s) async {
      await pumpEventQueue();
      return (s as NativeModes).nativeModes.first;
    }

    test('a pick is session/set_mode; the agent moving itself to another mode stands', () async {
      final r = rig(['acp/goose_native_mode.jsonl']);
      final s = await r.driver('goose', 'goose').start(r.spec());
      final seen = _Seen(s);
      final set = await modesOf(s);
      expect(
        [for (final m in set.modes) (m.id, m.policy, m.blocked)],
        [
          ('auto', AgentMode.fullAuto, null),
          ('approve', AgentMode.ask, null),
          ('smart_approve', AgentMode.autoEdit, null),
          ('chat', AgentMode.plan, null),
        ],
      );
      expect(set.current, 'approve');
      await (s as NativeModes).setNativeMode('chat');
      await seen.until(() => r.channels.single.sent.where((m) => m['method'] == 'session/set_mode').length == 2);
      await s.send('go');
      await seen.untilStatus(ExecutionStatus.finished);
      r.expectPlayed();
      expect(seen.notices, isEmpty);
      expect((await modesOf(s)).current, 'auto');
      await s.close();
    });
  });
}

final class _NoTty implements LineChannel {
  @override
  Stream<String> get lines => const Stream.empty();

  @override
  void send(String line) {}

  @override
  String get lastError => 'Error: Device not configured (os error 6)';

  @override
  Future<KillOutcome> close() async => const Ended([]);
}
