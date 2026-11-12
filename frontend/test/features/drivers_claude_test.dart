import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/drivers/briefing/briefing_types.dart';
import 'package:every_ai/features/code/drivers/briefing/recipes.dart' show claudeSettingsJson;
import 'package:every_ai/features/code/drivers/claude/claude_driver.dart';
import 'package:every_ai/features/code/drivers/claude/claude_wire.dart';
import 'package:every_ai/features/code/drivers/driver.dart';
import 'package:every_ai/features/code/drivers/driver_policy.dart';
import 'package:every_ai/features/code/drivers/json_rpc.dart';
import 'package:every_ai/features/code/drivers/usage_limit.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/replay_transport.dart';

// Recorded from claude 2.1.318 (scrubbed; see
// docs/research/batches/multi-harness/run2/c1.md), with our initialize request.
String _fixture(String name) => File('test/fixtures/drivers/claude/$name').readAsStringSync();

typedef _Spawned = ({List<String> args, String cwd, Map<String, String> env});

/// Hands out [channels] in order and records how each process was started.
final class _Spawner {
  _Spawner(this.channels);
  final List<LineChannel> channels;
  final calls = <_Spawned>[];

  Future<LineChannel> call(
    List<String> args, {
    required String cwd,
    required Map<String, String> env,
    required String sessionTag,
    required String logPath,
  }) async {
    calls.add((args: args, cwd: cwd, env: env));
    if (channels.isEmpty) throw StateError('no CLI here');
    return channels.removeAt(0);
  }
}

SessionSpec _spec({
  String? message,
  AgentMode mode = AgentMode.ask,
  String model = 'haiku',
  String? effort,
  DriverBriefing? briefing,
}) => SessionSpec(
  workingDir: '/work/repo',
  model: model,
  mode: mode,
  llmBaseUrl: '',
  llmApiKey: '',
  sessionTag: 'tag-1',
  initialMessage: message,
  effort: effort,
  briefing: briefing,
);

const _pixel = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC';

/// Plays [session]'s events into a list; [onEvent] may answer them.
List<HarnessEvent> _record(HarnessSession session, [void Function(HarnessEvent e)? onEvent]) {
  final out = <HarnessEvent>[];
  session.events.listen((e) {
    out.add(e);
    onEvent?.call(e);
  });
  return out;
}

bool _isState(HarnessEvent e, ExecutionStatus s) => e is StateChange && e.executionStatus == s;

Future<void> _played(ReplayChannel c) async {
  await c.finished;
  await pumpEventQueue();
  c.expectFinished();
}

// Short scripts for the CLI's side, built from the wire helpers.
final _init = [
  _out(controlRequest('req_1', {'subtype': 'initialize'})),
  _in(controlResponse('req_1', const {})),
].join('\n');
String _out(Map<String, Object?> msg) => jsonEncode({'dir': 'out', 'msg': msg});
String _in(Map<String, Object?> msg) => jsonEncode({'dir': 'in', 'msg': msg});
String _say(String text) => _out(userLine(text));
String _done(String uuid, {bool aborted = false}) => _in({
  'type': 'result',
  'subtype': aborted ? 'error_during_execution' : 'success',
  'is_error': aborted,
  if (aborted) 'terminal_reason': 'aborted_streaming',
  'usage': {'input_tokens': 0, 'output_tokens': 0},
  'uuid': uuid,
});
String _use(String callId, String name, Map<String, Object?> input, {String? parent}) => _in({
  'type': 'assistant',
  'message': {
    'id': 'm-$callId',
    'role': 'assistant',
    'content': [
      {'type': 'tool_use', 'id': callId, 'name': name, 'input': input},
    ],
  },
  'parent_tool_use_id': parent,
  'uuid': 'u-$callId',
});

/// Claude's permission prompt for a call (its own mode chose to ask).
String _prompt(String requestId, String callId, String name, Map<String, Object?> input) => _in({
  'type': 'control_request',
  'request_id': requestId,
  'request': {'subtype': 'can_use_tool', 'tool_name': name, 'input': input, 'tool_use_id': callId},
});
String _allow(String requestId, Map<String, Object?> input) =>
    _out(controlResponse(requestId, approvalAnswer(accept: true, input: input)));
String _results(List<String> callIds) => _in({
  'type': 'user',
  'message': {
    'role': 'user',
    'content': [
      for (final id in callIds) {'type': 'tool_result', 'tool_use_id': id, 'content': 'ok', 'is_error': false},
    ],
  },
  'uuid': 'res-${callIds.join()}',
});
Map<String, Object?> _msg(String line) => (jsonDecode(line) as Map<String, Object?>)['msg']! as Map<String, Object?>;
String _script(List<String> lines) => '${lines.join('\n')}\n';

// A background subagent, as Claude Code 2.1.319 streams it: the Agent call, its task, the launch notice, the
// subagent's own frames (parent_tool_use_id set), and the task's notification when it ends.
const _explore = {'description': 'Map the coach', 'prompt': 'Find the coach code.', 'subagent_type': 'Explore'};
Map<String, Object?> _taskStarted(String callId, {bool background = true}) => {
  'type': 'system',
  'subtype': 'task_started',
  'task_id': 'task-$callId',
  'tool_use_id': callId,
  'description': 'Map the coach',
  'subagent_type': 'Explore',
  'is_backgrounded': background,
  'task_type': 'local_agent',
};
Map<String, Object?> _launched(String callId) => {
  'type': 'user',
  'message': {
    'role': 'user',
    'content': [
      {
        'type': 'tool_result',
        'tool_use_id': callId,
        'content': [
          {'type': 'text', 'text': 'Async agent launched successfully.\nagentId: a1 (internal ID)'},
        ],
      },
    ],
  },
  'uuid': 'launch-$callId',
};
Map<String, Object?> _inner(String parent) => {
  'type': 'assistant',
  'message': {
    'content': [
      {'type': 'text', 'text': "I'm the subagent."},
      {
        'type': 'tool_use',
        'id': 'inner-1',
        'name': 'Bash',
        'input': {'command': 'ls'},
      },
    ],
  },
  'parent_tool_use_id': parent,
  'uuid': 'inner-a',
};
Map<String, Object?> _innerResult(String parent) => {
  'type': 'user',
  'message': {
    'content': [
      {'type': 'tool_result', 'tool_use_id': 'inner-1', 'content': 'src'},
    ],
  },
  'parent_tool_use_id': parent,
  'uuid': 'inner-u',
};
Map<String, Object?> _notified(String callId, {String status = 'completed', Map<String, Object?>? report}) => {
  'type': 'system',
  'subtype': 'task_notification',
  'task_id': 'task-$callId',
  'tool_use_id': callId,
  'status': status,
  'output_file': '/tmp/x.output',
  'summary': 'Agent "Map the coach" completed',
  'handback_report': ?report,
};
Map<String, Object?> _words(String uuid, String text) => {
  'type': 'assistant',
  'message': {
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
  'parent_tool_use_id': null,
  'uuid': uuid,
};

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('claude_driver'));
  tearDown(() => tmp.deleteSync(recursive: true));

  ClaudeDriver driver(_Spawner s) => ClaudeDriver(dataDir: () async => tmp.path, spawn: s.call);

  group('command line', () {
    test('flags come in a fixed order, for a new session and a resumed one', () {
      final fresh = claudeLaunch(sessionId: 'abc', resume: false, mode: AgentMode.ask, model: 'haiku', effort: 'high');
      expect(fresh.args, [
        '-p',
        '--input-format',
        'stream-json',
        '--output-format',
        'stream-json',
        '--verbose',
        '--include-partial-messages',
        '--permission-prompt-tool',
        'stdio',
        '--permission-mode',
        'default',
        '--allow-dangerously-skip-permissions',
        '--setting-sources',
        'user',
        '--session-id',
        'abc',
        '--model',
        'haiku',
        '--effort',
        'high',
        '--settings',
        claudeSettingsJson(),
      ]);
      final resumed = claudeLaunch(sessionId: 'abc', resume: true, mode: AgentMode.plan, model: 'default');
      expect(resumed.args.sublist(9), [
        '--permission-mode',
        'plan',
        '--allow-dangerously-skip-permissions',
        '--setting-sources',
        'user',
        '--resume',
        'abc',
        '--settings',
        claudeSettingsJson(),
      ]);
      // A project's own .claude settings (hooks, apiKeyHelper, env) never load, nor in the models probe.
      expect(claudeProbeArgs, containsAllInOrder(['--setting-sources', 'user']));
      for (final a in [fresh.args, resumed.args]) {
        expect(a, isNot(contains('--dangerously-skip-permissions')));
        expect(a, isNot(contains('--max-turns')));
        expect(a, isNot(contains('--disallowedTools')));
      }
      expect(fresh.env, {'MCP_TOOL_TIMEOUT': '330000', 'CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT': '330000'});
    });

    test('our modes map onto Claude permission modes', () {
      expect(
        {for (final m in AgentMode.values) m: permissionModeFor(m)},
        {
          AgentMode.ask: 'default',
          AgentMode.autoEdit: 'acceptEdits',
          AgentMode.plan: 'plan',
          AgentMode.auto: 'auto',
          AgentMode.fullAuto: 'bypassPermissions',
          AgentMode.bypass: 'bypassPermissions',
        },
      );
    });
  });

  group('tool calls', () {
    test('map onto the app\'s kinds with the fields the rules read', () {
      final d = ClaudeDecoder();
      final bash = d.action('1', 'Bash', {'command': 'ls', 'description': 'list'});
      final edit = d.action('2', 'Edit', {'file_path': '/r/a.dart', 'old_string': 'a', 'new_string': 'b'});
      final write = d.action('3', 'Write', {'file_path': '/r/b.txt', 'content': 'hi'});
      final read = d.action('4', 'Read', {'file_path': '/r/a.dart'});
      final nb = d.action('5', 'NotebookEdit', {'notebook_path': '/r/n.ipynb', 'new_source': 'x'});
      final mcp = d.action('6', 'mcp__github__create_issue', {'title': 't'});
      final other = d.action('7', 'ExitPlanMode', {'plan': 'p'});
      final todo = d.action('8', 'TodoWrite', {
        'todos': [
          {'content': 'Fix it', 'status': 'completed', 'activeForm': 'Fixing it'},
        ],
      });
      expect(
        [
          for (final c in [bash, edit, write, read, nb, mcp, other, todo]) c.actionKind,
        ],
        [
          'TerminalAction',
          'FileEditorAction',
          'FileEditorAction',
          'ReadFileAction',
          'FileEditorAction',
          'MCPToolAction',
          'ProposedPlanAction',
          'TaskTrackerAction',
        ],
      );
      expect(bash.str('command'), 'ls');
      expect(
        (edit.str('command'), edit.str('path'), edit.str('old_str'), edit.str('new_str')),
        ('str_replace', '/r/a.dart', 'a', 'b'),
      );
      expect(edit.action.containsKey('file_path'), isFalse);
      expect((write.str('command'), write.str('path'), write.str('file_text')), ('create', '/r/b.txt', 'hi'));
      expect(read.str('path'), '/r/a.dart');
      expect(nb.str('path'), '/r/n.ipynb');
      expect(mcp.toolName, 'mcp__github__create_issue');
      expect(other.str('body'), 'p');
      expect(todo.action['task_list'], [
        {'title': 'Fix it', 'status': 'done', 'active': 'Fixing it'},
      ]);
      for (final c in [bash, edit, write, read, nb, mcp, todo]) {
        expect(autoDecidable(c), isTrue, reason: c.toolName);
      }
      expect(autoDecidable(other), isFalse);
      expect(answeredBySession('mcp__everyai__ask_user_question', briefed: true), isTrue);
      // Without a briefing a server named everyai is the user's own, not ours.
      expect(answeredBySession('mcp__everyai__ask_user_question', briefed: false), isFalse);
      expect(answeredBySession('Skill', briefed: false), isTrue);
      expect(answeredBySession('Bash', briefed: true), isFalse);
      expect(answeredBySession('mcp__github__create_issue', briefed: true), isFalse);
    });

    test("Claude's web tools always ask: they skip our safe fetcher and secret scrubber", () {
      final d = ClaudeDecoder();
      final fetch = d.action('1', 'WebFetch', {'url': 'https://example.com/?d=x', 'prompt': 'p'});
      final search = d.action('2', 'WebSearch', {'query': 'q'});
      for (final c in [fetch, search]) {
        expect(AgentMode.isReadOnly(c), isFalse, reason: c.toolName);
        expect(autoDecidable(c), isFalse, reason: c.toolName);
        expect(AgentMode.ask.autoApproves(c), isFalse, reason: c.toolName);
      }
      expect(fetch.str('url'), 'https://example.com/?d=x');
    });
  });

  group('usage limits', () {
    // Shapes from Claude Code 2.1.318's wire serializer (run3/u1.md).
    Map<String, Object?> apiError(String text, {String error = 'rate_limit', String? api, num? resetsAt}) => {
      'type': 'assistant',
      'uuid': 'a-${text.hashCode}',
      'is_api_error_message': true,
      'error': error,
      'api_error_status': 429,
      'api_error': ?api,
      if (resetsAt != null)
        'api_error_params': {
          'rate_limit_info': {'status': 'rejected', 'resetsAt': resetsAt, 'rateLimitType': 'five_hour'},
        },
      'message': {
        'content': [
          {'type': 'text', 'text': text},
        ],
      },
    };
    Map<String, Object?> failed(String text) => {
      'type': 'result',
      'uuid': 'r-${text.hashCode}',
      'subtype': 'success',
      'is_error': true,
      'result': text,
      'api_error_status': 429,
    };

    test('a plan limit ends the turn as a usage limit with its reset time', () {
      final d = ClaudeDecoder();
      const text = "You've hit your limit · resets 3pm";
      d.decode(apiError(text, api: 'usage_limit_reached', resetsAt: 1800000000));
      final limit = d.decode(failed(text)).map(usageLimitOf).nonNulls.single;
      expect(limit.message, text);
      expect(limit.resetsAt, DateTime.fromMillisecondsSinceEpoch(1800000000 * 1000, isUtc: true));
    });
  });

  group('subagents', () {
    test("Claude's Agent call is a subagent card; the subagent's own frames stay off the transcript", () {
      final d = ClaudeDecoder();
      final call = d.decode(_msg(_use('t1', 'Agent', _explore))).single as ActionCall;
      expect(call.actionKind, 'TaskAction');
      expect(call.action, containsPair('agent', 'Explore'));
      expect(d.decode(_taskStarted('t1')), isEmpty);
      // The launch notice isn't the subagent's result.
      expect(d.decode(_launched('t1')), isEmpty);
      expect(d.hasBackground, isTrue);
      expect((TranscriptBuilder()..add(call)).snapshot.items.whereType<SubagentItem>().single.done, isFalse);
      expect(d.decode(_inner('t1')), isEmpty);
      expect(d.decode(_innerResult('t1')), isEmpty);
      final report = d.decode(_notified('t1', report: {'text': 'The coach lives in lib/review.'})).single as ToolResult;
      expect((report.actionId, report.text, report.outcome), ('t1', 'The coach lives in lib/review.', ToolOutcome.ok));
      expect(d.hasBackground, isFalse);

      final t = TranscriptBuilder()
        ..add(call)
        ..add(report);
      final card = t.snapshot.items.whereType<SubagentItem>().single;
      expect((card.task.title, card.task.agent, card.done), ('Map the coach', 'Explore', true));
    });

    test('a session wakes when a background subagent reports, and its card gets the report', () async {
      final channel = ReplayChannel(
        _script([
          _init,
          _say('Look around.'),
          _use('t1', 'Agent', _explore),
          _in(_taskStarted('t1')),
          _in(_launched('t1')),
          _in(_inner('t1')),
          _in(_innerResult('t1')),
          _done('r1'),
          _in(_notified('t1', report: {'text': 'Found it.'})),
          _in(_words('w1', 'The subagent found it.')),
          _done('r2'),
        ]),
      );
      final session = await driver(_Spawner([channel])).start(_spec());
      final events = _record(session);
      await session.send('Look around.');
      await _played(channel);

      final states = [
        for (final e in events)
          if (e is StateChange && e.executionStatus != ExecutionStatus.unknown) e.executionStatus,
      ];
      expect(states, [
        ExecutionStatus.running,
        ExecutionStatus.finished,
        ExecutionStatus.running,
        ExecutionStatus.finished,
      ]);
      expect(events.whereType<ActionCall>().map((c) => c.id), ['t1']);
      expect(events.whereType<ChatMessage>().where((m) => !m.fromUser).map((m) => m.text), ['The subagent found it.']);
      final t = TranscriptBuilder();
      events.forEach(t.add);
      final card = t.snapshot.items.whereType<SubagentItem>().single;
      expect((card.step.result?.text, card.done), ('Found it.', true));
      await session.close();
    });
  });

  group('resume check', () {
    test("a session the CLI no longer holds is reported; one it holds, or never sent, isn't", () async {
      final config = Directory('${tmp.path}/config')..createSync();
      Directory('${tmp.path}/config/projects').createSync();
      ClaudeDriver again() => ClaudeDriver(dataDir: () async => tmp.path, configDir: config.path);
      final channel = ReplayChannel(_fixture('init_image_turn.jsonl'));
      final session = await driver(_Spawner([channel])).start(_spec());
      // Nothing was sent yet: the CLI has nothing to resume.
      expect(await again().resumeProblem(session.id), isNull);
      await session.send('What colour is this pixel? Reply in one word.', images: ['data:image/png;base64,$_pixel']);
      await _played(channel);
      await session.close();
      expect(await again().resumeProblem(session.id), contains('no longer has'));
      // The CLI names the folder's store after the path with each other character a dash.
      File('${config.path}/projects/-work-repo/${session.id}.jsonl')
        ..createSync(recursive: true)
        ..writeAsStringSync('{}');
      expect(await again().resumeProblem(session.id), isNull);
      expect(await again().resumeProblem('gone'), contains('record is gone'));
    });
  });

  group('sessions', () {
    test('a turn with a picture: initialize first, image sent, usage on the plan, then finished', () async {
      final channel = ReplayChannel(_fixture('init_image_turn.jsonl'));
      final s = _Spawner([channel]);
      final session = await driver(s).start(_spec());
      final events = _record(session);
      // Nothing starts before the first message.
      expect(s.calls, isEmpty);
      await session.send('What colour is this pixel? Reply in one word.', images: ['data:image/png;base64,$_pixel']);
      await _played(channel);

      expect(channel.sent.first['request'], {'subtype': 'initialize'});
      expect(s.calls.single.args, containsAllInOrder(['--session-id', session.id, '--model', 'haiku']));
      expect(s.calls.single.cwd, '/work/repo');
      final shown = [
        for (final e in events)
          if (e is! StreamDelta) e,
      ];
      expect(shown.first, isA<ChatMessage>().having((m) => m.fromUser, 'fromUser', isTrue));
      expect(_isState(shown[1], ExecutionStatus.running), isTrue);
      expect(events.whereType<StreamDelta>().map((d) => d.content).join(), 'Red.');
      final agent = shown.whereType<ChatMessage>().where((m) => !m.fromUser).single;
      expect(agent.text, 'Red.');
      final usage = shown.whereType<UsageReport>().single;
      expect(
        (usage.input, usage.cached, usage.output, usage.costMicros, usage.contextTokens, usage.onPlan),
        (23127, 12932, 120, 2228, 23127, true),
      );
      expect(_isState(shown.last, ExecutionStatus.finished), isTrue);
      await session.close();
    });

    test("a call Claude's permission prompt asks about waits until it is answered, then runs", () async {
      final channel = ReplayChannel(_fixture('prompt_allow.jsonl'));
      final session = await driver(_Spawner([channel]))
          .start(_spec(message: 'Run the shell command `touch a.txt` with the Bash tool, then reply DONE.'));
      final events = _record(session, (e) {
        if (_isState(e, ExecutionStatus.waitingForConfirmation)) {
          unawaited(session.respond(accept: true, callIds: ['toolu_0529b669']));
        }
      });
      await _played(channel);

      final call = events.whereType<ActionCall>().single;
      expect(
        (call.id, call.actionKind, call.str('command'), call.toolName),
        ('toolu_0529b669', 'TerminalAction', 'touch a.txt', 'Bash'),
      );
      final states = [
        for (final e in events)
          if (e is StateChange && e.key != approvedCallsKey && e.key != escalatedCallsKey) e.executionStatus,
      ];
      expect(states, [
        ExecutionStatus.running,
        ExecutionStatus.waitingForConfirmation,
        ExecutionStatus.running,
        ExecutionStatus.finished,
      ]);
      final result = events.whereType<ToolResult>().single;
      expect((result.actionId, result.outcome), ('toolu_0529b669', ToolOutcome.ok));
      expect(events.indexOf(result), greaterThan(events.indexOf(call)));
      expect(channel.sent[2]['response'], {
        'subtype': 'success',
        'request_id': '00000000-0000-4000-8000-000000000003',
        'response': {
          'behavior': 'allow',
          'updatedInput': {'command': 'touch a.txt', 'description': 'Create empty file a.txt in current directory'},
        },
      });
      await session.close();
    });

    test("Allow for this session sends Claude's suggested rule back for the session, never its mode change", () async {
      final channel = ReplayChannel(_fixture('prompt_allow_session.jsonl'));
      final session = await driver(_Spawner([channel]))
          .start(_spec(message: 'Run the shell command `touch a.txt` with the Bash tool, then reply DONE.'));
      _record(session, (e) {
        if (_isState(e, ExecutionStatus.waitingForConfirmation)) {
          unawaited((session as AllowsRemembered).allowRemembered(NativeGrant.session, callIds: ['toolu_0529b669']));
        }
      });
      await _played(channel);
      await session.close();
    });

    test('a refused permission prompt goes back to the model, which carries on', () async {
      final channel = ReplayChannel(_fixture('deny_write.jsonl'));
      final session = await driver(_Spawner([channel])).start(
        _spec(
          message: 'Now create a file named note.txt containing the word hi using the Write tool, then reply DONE.',
        ),
      );
      final events = _record(session, (e) {
        if (_isState(e, ExecutionStatus.waitingForConfirmation)) {
          unawaited(session.respond(accept: false, reason: 'The user said no.', callIds: ['toolu_00224ce4']));
        }
      });
      await _played(channel);

      final call = events.whereType<ActionCall>().single;
      expect((call.actionKind, call.str('path')), ('FileEditorAction', '/work/repo/note.txt'));
      final result = events.whereType<ToolResult>().single;
      expect(
        (result.actionId, result.outcome, result.observation['reason']),
        ('toolu_00224ce4', ToolOutcome.rejected, 'The user said no.'),
      );
      final states = [
        for (final e in events)
          if (e is StateChange && e.key != approvedCallsKey && e.key != escalatedCallsKey) e.executionStatus,
      ];
      expect(states, isNot(contains(ExecutionStatus.paused)));
      expect(states.last, ExecutionStatus.finished);
      expect(events.whereType<ChatMessage>().last.text, startsWith("I didn't create `note.txt`."));
      await session.close();
    });

    test('Stop interrupts the turn over the control channel; the aborted turn pauses and reports nothing', () async {
      final channel = ReplayChannel(_fixture('interrupt.jsonl'));
      final session = await driver(_Spawner([channel]))
          .start(_spec(message: 'Write the numbers 1 to 300 separated by spaces, no tools.'));
      final streaming = Completer<void>();
      final events = _record(session, (e) {
        if (e is StreamDelta && !streaming.isCompleted) streaming.complete();
      });
      await streaming.future;
      await session.interrupt();
      await _played(channel);

      expect(channel.sent[2], {
        'type': 'control_request',
        'request_id': 'req_2',
        'request': {'subtype': 'interrupt'},
      });
      expect(events.whereType<UsageReport>(), isEmpty);
      expect(_isState(events.last, ExecutionStatus.paused), isTrue);
      await session.close();
    });

    test('a reopened session replays its journal, starts nothing, and resumes on the next message', () async {
      final first = ReplayChannel(_fixture('prompt_allow.jsonl'));
      final one = await driver(_Spawner([first]))
          .start(_spec(message: 'Run the shell command `touch a.txt` with the Bash tool, then reply DONE.'));
      final before = _record(one, (e) {
        if (_isState(e, ExecutionStatus.waitingForConfirmation)) unawaited(one.respond(accept: true));
      });
      await _played(first);
      await one.close();

      final resumed = ReplayChannel(_fixture('resume_echo.jsonl'));
      final s = _Spawner([resumed]);
      final again = driver(s);
      final two = await again.attach(one.id);
      final after = _record(two);
      await pumpEventQueue();
      expect(s.calls, isEmpty);
      final ids = [
        for (final e in before)
          if (e is! StreamDelta) e.id,
      ];
      expect([for (final e in after) e.id].take(ids.length), ids);
      expect(_isState(after.last, ExecutionStatus.idle), isTrue);
      expect(await again.statuses([one.id, 'other']), {one.id: ExecutionStatus.idle});

      await two.send('Run the shell command `echo hi` with the Bash tool, then reply DONE.');
      await _played(resumed);
      expect(s.calls.single.args, containsAllInOrder(['--resume', one.id]));
      expect(s.calls.single.args, isNot(contains('--session-id')));
      expect(s.calls.single.cwd, '/work/repo');
      expect(after.whereType<ToolResult>().last.text, 'hi');
      expect(_isState(after.last, ExecutionStatus.finished), isTrue);
      await expectLater(two.rewindTo(null), throwsA(isA<HarnessError>()));
      await two.close();
    });

    test('Retry after the CLI died mid-turn runs the turn on in a resumed process', () async {
      final first = ReplayChannel(
        _script([
          _init,
          _say('Go.'),
          _in({'type': 'system', 'subtype': 'init'}),
          '{"dir":"eof"}',
        ]),
      );
      final second = ReplayChannel(_script([_init, _say(continueMessage), _done('r2')]));
      final s = _Spawner([first, second]);
      final session = await driver(s).start(_spec(message: 'Go.'));
      final events = _record(session);
      await _played(first);
      expect(_isState(events.last, ExecutionStatus.error), isTrue);

      await session.resume();
      await _played(second);
      expect(s.calls[1].args, containsAllInOrder(['--resume', session.id]));
      expect(_isState(events.last, ExecutionStatus.finished), isTrue);
      // Not something the user typed.
      expect(events.whereType<ChatMessage>().where((m) => m.text == continueMessage), isEmpty);
      // After a finished turn there is nothing to run on.
      await session.resume();
      expect(second.failures, isEmpty);
      await session.close();
    });

    test('pause, then resume before the stopped turn has ended: it runs on once it has', () async {
      final channel = ReplayChannel(
        _script([
          _init,
          _say('Go.'),
          _in({'type': 'system', 'subtype': 'init'}),
          _out(controlRequest('req_2', {'subtype': 'interrupt'})),
          _in(controlResponse('req_2', const {})),
          _done('r1', aborted: true),
          _say(continueMessage),
          _done('r2'),
        ]),
      );
      final session = await driver(_Spawner([channel])).start(_spec(message: 'Go.'));
      final events = _record(session);
      await pumpEventQueue();
      await session.pause();
      await session.resume();
      await _played(channel);
      final states = [
        for (final e in events)
          if (e is StateChange && e.key != approvedCallsKey && e.key != escalatedCallsKey) e.executionStatus,
      ];
      expect(states, containsAllInOrder([ExecutionStatus.paused, ExecutionStatus.running, ExecutionStatus.finished]));
      await session.close();
    });

    test('interrupt, then send at once: the stopped turn\'s result neither pauses nor ends the new turn', () async {
      final channel = ReplayChannel(
        _script([
          _init,
          _say('Go.'),
          _in({'type': 'system', 'subtype': 'init'}),
          _out(controlRequest('req_2', {'subtype': 'interrupt'})),
          _say('Say BANANA.'),
          _in(controlResponse('req_2', const {})),
          _done('r1', aborted: true),
          _done('r2'),
        ]),
      );
      final session = await driver(_Spawner([channel])).start(_spec(message: 'Go.'));
      final events = _record(session);
      await pumpEventQueue();
      await session.interrupt();
      await session.send('Say BANANA.');
      await _played(channel);
      final states = [
        for (final e in events)
          if (e is StateChange && e.key != approvedCallsKey && e.key != escalatedCallsKey) e.executionStatus,
      ];
      expect(states, isNot(contains(ExecutionStatus.paused)));
      expect(states.where((s) => s == ExecutionStatus.finished), hasLength(1));
      expect(states.last, ExecutionStatus.finished);
      await session.close();
    });

    test("Auto: Claude's reviewer decides; a call it passes to the user asks, one it lets run doesn't", () async {
      const input = {'command': 'rm -rf build'};
      final channel = ReplayChannel(
        _script([
          _out(controlRequest('req_1', {'subtype': 'initialize'})),
          _in(
            controlResponse('req_1', const {
              'models': [
                {'value': 'haiku', 'supportsAutoMode': true},
              ],
              'current_permission_mode': 'auto',
            }),
          ),
          _say('Clean up.'),
          _use('toolu_s', 'Bash', {'command': 'ls'}),
          _use('toolu_r', 'Bash', input),
          _prompt('p1', 'toolu_r', 'Bash', input),
          _allow('p1', input),
          _results(['toolu_s', 'toolu_r']),
          _done('r1'),
        ]),
      );
      final session = await driver(_Spawner([channel])).start(_spec(message: 'Clean up.', mode: AgentMode.auto));
      final t = TranscriptBuilder();
      final asked = <List<String>>[];
      final events = _record(session, (e) {
        t.add(e);
        if (_isState(e, ExecutionStatus.waitingForConfirmation)) {
          asked.add([for (final c in t.snapshot.pending) c.id]);
          unawaited(session.respond(accept: true, callIds: ['toolu_r']));
        }
      });
      await _played(channel);
      expect(asked, [
        ['toolu_r'],
      ]);
      // Shown as running when it streamed in, then opened again by the prompt.
      expect(events.whereType<StateChange>().where((e) => e.key == escalatedCallsKey), hasLength(1));
      expect(t.snapshot.pending, isEmpty);
      await session.close();
    });

    test('attachBriefed: the resumed process carries the new token, not the old one; none is on disk', () async {
      const old = DriverBriefing(mcpUrl: 'http://127.0.0.1:7000/mcp', mcpToken: 'tok-old');
      const fresh = DriverBriefing(mcpUrl: 'http://127.0.0.1:7001/mcp', mcpToken: 'tok-new');
      final first = ReplayChannel(_script([_init, _say('Go.'), _done('r1')]));
      final s1 = _Spawner([first]);
      final one = await driver(s1).start(_spec(message: 'Go.', briefing: old));
      await _played(first);
      expect(s1.calls.single.env[tokenEnvVar], 'tok-old');
      await one.close();

      final resumed = ReplayChannel(_script([_init, _say('Next.'), _done('r2')]));
      final s2 = _Spawner([resumed]);
      final two = await driver(s2).attachBriefed(one.id, fresh);
      await two.send('Next.');
      await _played(resumed);
      final call = s2.calls.single;
      expect(call.env[tokenEnvVar], 'tok-new');
      expect(call.args, containsAllInOrder(['--resume', one.id]));
      expect(call.args.join(' '), contains('127.0.0.1:7001'));
      expect(call.args.join(' '), isNot(contains('tok-')));
      for (final f in tmp.listSync(recursive: true).whereType<File>()) {
        expect(f.readAsStringSync(), isNot(contains('tok-')), reason: f.path);
      }
      await two.close();

      // Without a briefing it reopens with no MCP server of ours.
      final bare = ReplayChannel(_script([_init, _say('Bare.'), _done('r3')]));
      final s3 = _Spawner([bare]);
      final three = await driver(s3).attach(one.id);
      await three.send('Bare.');
      await _played(bare);
      expect(s3.calls.single.env.containsKey(tokenEnvVar), isFalse);
      expect(s3.calls.single.args, isNot(contains('--mcp-config')));
      await three.close();
    });
  });

  group('driver', () {
    test('detect reads only whether the CLI is signed in', () async {
      Future<DriverStatus> withAuth(String? out) => ClaudeDriver(
        which: (_) async => '/bin/echo',
        run: (exe, args) async {
          expect(exe, '/bin/echo');
          expect(args, ['auth', 'status', '--json']);
          return out;
        },
      ).detect();
      final yes = await withAuth('{"loggedIn":true,"authMethod":"claude.ai","email":"x@y.z"}');
      expect((yes.installed, yes.path, yes.signedIn, yes.problem), (true, '/bin/echo', true, null));
      final no = await withAuth('{"loggedIn":false}');
      expect(no.signedIn, isFalse);
      expect(no.problem, contains('claude auth login'));
      final unsure = await withAuth('Error: unknown command');
      expect((unsure.installed, unsure.signedIn, unsure.problem), (true, null, null));
      final missing = await ClaudeDriver(which: (_) async => null).detect();
      expect(missing.installed, isFalse);
    });
  });

  group('native commands', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('claude_native'));
    tearDown(() => dir.deleteSync(recursive: true));

    // Derived from the Agent SDK's initialize reply (the recordings scrub it to []).
  });

  group('native modes', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('claude_modes'));
    tearDown(() => dir.deleteSync(recursive: true));
    ClaudeDriver driverIn(_Spawner s) => ClaudeDriver(dataDir: () async => dir.path, spawn: s.call);
    String setMode(String req, String mode) =>
        _out(controlRequest(req, {'subtype': 'set_permission_mode', 'mode': mode}));

    test('a switch is set_permission_mode under the native id; an unlisted one throws and sends nothing', () async {
      final channel = ReplayChannel(
        _script([
          _init,
          _say('Go.'),
          _done('r1'),
          setMode('req_2', 'acceptEdits'),
          setMode('req_3', 'bypassPermissions'),
        ]),
      );
      final session = await driverIn(_Spawner([channel])).start(_spec(message: 'Go.'));
      final native = session as NativeModes;
      await pumpEventQueue();
      await native.setNativeMode('acceptEdits');
      await native.setNativeMode('bypassPermissions');
      await _played(channel);
      final sent = channel.sent.length;
      await expectLater(native.setNativeMode('dontAsk'), throwsA(isA<HarnessError>()));
      expect(channel.sent.length, sent);
      expect((await native.nativeModes.first).current, 'bypassPermissions');
      await session.close();
    });

    test('an approved ExitPlanMode moves Claude back to the mode before plan', () async {
      final plan = {'plan': 'Do it.'};
      final channel = ReplayChannel(
        _script([
          _init,
          _say('Plan it.'),
          setMode('req_2', 'plan'),
          _use('toolu_p', 'ExitPlanMode', plan),
          _prompt('h1', 'toolu_p', 'ExitPlanMode', plan),
          _allow('h1', plan),
          setMode('req_3', 'acceptEdits'),
          _results(['toolu_p']),
          _done('r1'),
        ]),
      );
      final session = await driverIn(_Spawner([channel])).start(_spec(mode: AgentMode.autoEdit, message: 'Plan it.'));
      final native = session as NativeModes;
      final seen = <String?>[];
      native.nativeModes.listen((m) => seen.add(m.current));
      _record(session, (e) {
        if (_isState(e, ExecutionStatus.waitingForConfirmation)) {
          unawaited(session.respond(accept: true, callIds: ['toolu_p']));
        }
      });
      await pumpEventQueue();
      await native.setNativeMode('plan');
      await _played(channel);
      expect(seen, ['acceptEdits', 'plan', 'acceptEdits']);
      await session.close();
    });
  });
}

/// A CLI side the test feeds by hand: it answers initialize and counts interrupts.
