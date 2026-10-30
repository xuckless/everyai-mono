import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../../domain/agent_mode.dart';
import '../../domain/compaction.dart';
import '../../domain/subagents.dart' show forkingTaskSpec, subagentRules, taskTool;
import '../../settings/agent_prompt.dart' show forHeldClientTools;
import '../events.dart';
import '../harness.dart';
import '../openhands_harness.dart' show HarnessError;
import 'llm.dart';
import 'prompt_io.dart';
import 'shell_io.dart';
import 'tools_io.dart';

/// The EveryAI harness: the agent loop runs here, in the app, against the
/// gateway. It speaks the same events as the agent-server (the transcript,
/// permissions and approvals are shared), but the loop, the tools and the
/// history are ours: questions block inside the call, tool results can be cut
/// to size, and a session can be forked from another's history.
final class EveryAIHarness implements Harness {
  EveryAIHarness({required this.dataDir, required this.gatewayKey, this.client});

  /// App Support; sessions are kept under `everyai-sessions/<id>/`.
  final Future<String> Function() dataDir;

  /// The user's gateway key, asked for when a session is reopened (it isn't
  /// written to disk with the session).
  final Future<String> Function() gatewayKey;
  final http.Client? client;

  final _sessions = <String, EveryAISession>{};

  Future<Directory> _dirFor(String id) async =>
      Directory('${await dataDir()}/everyai-sessions/$id')..createSync(recursive: true);

  @override
  Future<HarnessSession> start(SessionSpec spec) async {
    final id = const Uuid().v4();
    final session = EveryAISession._(id, spec, await _dirFor(id), client);
    _sessions[id] = session;
    await session._begin();
    return session;
  }

  /// A new session that starts from [parentId]'s history up to now (a fork):
  /// the same system prompt and tools, so the model's cached prefix holds,
  /// then [spec]'s initial message as the directive.
  Future<HarnessSession> fork(String parentId, SessionSpec spec) async {
    final parent = _sessions[parentId] ?? (await attach(parentId)) as EveryAISession;
    final id = const Uuid().v4();
    final session = EveryAISession._(id, spec, await _dirFor(id), client);
    _sessions[id] = session;
    await session._beginFork(parent);
    return session;
  }

  @override
  Future<HarnessSession> attach(String conversationId) async {
    if (_sessions[conversationId] case final s?) return s;
    final dir = Directory('${await dataDir()}/everyai-sessions/$conversationId');
    if (!dir.existsSync()) {
      throw const HarnessError("This session's history is no longer on this computer, so it can't be resumed.");
    }
    final session = await EveryAISession._load(conversationId, dir, await gatewayKey(), client);
    _sessions[conversationId] = session;
    return session;
  }

  @override
  Future<Map<String, ExecutionStatus>> statuses(List<String> conversationIds) async {
    final root = '${await dataDir()}/everyai-sessions';
    return {
      for (final id in conversationIds)
        if (_sessions[id] case final s?)
          id: s.status
        else if (Directory('$root/$id').existsSync())
          id: ExecutionStatus.idle,
    };
  }
}

/// Most model calls one run makes before it is asked to wrap up.
const maxStepsPerRun = 400;

/// One conversation: its history (OpenAI-style messages), its events, and the
/// loop that calls the model and runs tools.
final class EveryAISession implements HarnessSession, AsksAside {
  EveryAISession._(this.id, this._spec, this._dir, http.Client? client)
    : _gateway = GatewayClient(baseUrl: _spec.llmBaseUrl, apiKey: _spec.llmApiKey, client: client),
      _shell = SessionShell(root: _spec.workingDir, sessionTag: _spec.sessionTag, scratchDir: '${_dir.path}/shell') {
    _tools = ToolRunner(root: _spec.workingDir, shell: _shell, gateway: _gateway, sessionTag: _spec.sessionTag);
  }

  @override
  final String id;
  SessionSpec _spec;
  final Directory _dir;
  GatewayClient _gateway;
  final SessionShell _shell;
  late ToolRunner _tools;

  /// The model's history; each entry may carry `_eid`, the event it came
  /// from (for rewinds), stripped before sending.
  final _messages = <Map<String, Object?>>[];

  /// Every event except streaming deltas, replayed to new listeners.
  final _history = <HarnessEvent>[];
  final _listeners = <StreamController<HarnessEvent>>{};

  ExecutionStatus status = ExecutionStatus.idle;

  /// Messages sent while a run is going: added before the next model call.
  final _inbox = <Map<String, Object?>>[];

  Completer<({bool accept, String? reason})>? _decision;

  bool _looping = false;
  bool _pauseRequested = false;
  Completer<void>? _cancel;

  /// Input tokens of the last model call: how full the context is.
  int lastPromptTokens = 0;

  /// For a fork: the parent's tool list, kept as it was so the cached prefix
  /// (tools, system prompt, history) matches.
  List<Map<String, Object?>>? _forkTools;
  bool get isFork => _forkTools != null;

  // ------------------------------------------------------------------ setup

  Future<void> _begin() async {
    _writeSpec();
    final system = await _systemPrompt();
    _append({'role': 'system', 'content': system});
    if (_spec.initialMessage case final first?) {
      await send(first, run: _spec.runInitial, images: _spec.initialImages);
    }
  }

  Future<void> _beginFork(EveryAISession parent) async {
    _forkTools = parent._toolSpecs;
    _writeSpec();
    _writeForkTools();
    // The parent's history as it stands, without a trailing assistant turn
    // whose tool calls have no results yet (the call that started the fork).
    final copy = [for (final m in parent._messages) Map.of(m)..remove('_eid')];
    _trimDangling(copy);
    for (final m in copy) {
      _append(m);
    }
    if (_spec.initialMessage case final first?) {
      await send(first, run: _spec.runInitial, images: _spec.initialImages);
    }
  }

  /// Drops a trailing assistant message whose tool calls are unanswered, so
  /// the history is valid to send.
  static void _trimDangling(List<Map<String, Object?>> messages) {
    final answered = <String>{
      for (final m in messages)
        if (m['role'] == 'tool') m['tool_call_id'] as String? ?? '',
    };
    while (messages.isNotEmpty) {
      final last = messages.last;
      final calls = last['tool_calls'] as List<Object?>?;
      if (last['role'] == 'assistant' &&
          calls != null &&
          calls.any((c) => !answered.contains((c as Map<String, Object?>)['id']))) {
        messages.removeLast();
        continue;
      }
      break;
    }
  }

  static Future<EveryAISession> _load(String id, Directory dir, String key, http.Client? client) async {
    final specJson = jsonDecode(File('${dir.path}/spec.json').readAsStringSync()) as Map<String, Object?>;
    final spec = _specFromJson(specJson, key);
    final s = EveryAISession._(id, spec, dir, client);
    final forkTools = File('${dir.path}/fork_tools.json');
    if (forkTools.existsSync()) {
      s._forkTools = (jsonDecode(forkTools.readAsStringSync()) as List<Object?>).cast<Map<String, Object?>>();
    }
    final messages = File('${dir.path}/messages.jsonl');
    if (messages.existsSync()) {
      for (final line in messages.readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        s._messages.add(jsonDecode(line) as Map<String, Object?>);
      }
    }
    final events = File('${dir.path}/events.jsonl');
    if (events.existsSync()) {
      for (final line in events.readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        s._history.add(HarnessEvent.decode(jsonDecode(line) as Map<String, Object?>));
      }
    }
    // A run cut off by quitting: its unanswered calls are dropped so the
    // history can be sent again.
    final before = s._messages.length;
    _trimDangling(s._messages);
    if (s._messages.length != before) s._rewriteMessages();
    s.status = ExecutionStatus.idle;
    return s;
  }

  void _writeSpec() => File('${_dir.path}/spec.json').writeAsStringSync(jsonEncode(_specToJson(_spec)));

  static Map<String, Object?> _specToJson(SessionSpec s) => {
    'working_dir': s.workingDir,
    'model': s.model,
    'mode': s.mode.name,
    'llm_base_url': s.llmBaseUrl,
    'session_tag': s.sessionTag,
    'max_input_tokens': s.maxInputTokens,
    'max_output_tokens': s.maxOutputTokens,
    'vision': s.vision,
    'effort': s.effort,
    'subagent': s.subagent,
    'tools': s.tools,
    'client_tools': s.clientTools,
    'auto_compact_at': s.autoCompactAt,
  };

  void _writeForkTools() {
    if (_forkTools case final t?) File('${_dir.path}/fork_tools.json').writeAsStringSync(jsonEncode(t));
  }

  static SessionSpec _specFromJson(Map<String, Object?> j, String key) => SessionSpec(
    workingDir: j['working_dir']! as String,
    model: j['model']! as String,
    mode: AgentMode.values.asNameMap()[j['mode']] ?? AgentMode.ask,
    llmBaseUrl: j['llm_base_url']! as String,
    llmApiKey: key,
    sessionTag: j['session_tag']! as String,
    maxInputTokens: (j['max_input_tokens'] as num?)?.toInt(),
    maxOutputTokens: (j['max_output_tokens'] as num?)?.toInt() ?? 64000,
    vision: j['vision'] == true,
    effort: j['effort'] as String?,
    subagent: j['subagent'] == true,
    tools: (j['tools'] as List<Object?>?)?.cast<String>(),
    clientTools: (j['client_tools'] as List<Object?>?)?.cast<Map<String, Object?>>(),
    autoCompactAt: (j['auto_compact_at'] as num?)?.toDouble() ?? 0.6,
  );

  Future<String> _systemPrompt() async {
    final spec = _spec;
    final suffix = spec.promptSuffix == null ? '' : forHeldClientTools(spec.promptSuffix!);
    final parts = [
      harnessRules,
      ?spec.persona,
      if (suffix.isNotEmpty) suffix,
      if (spec.subagent) subagentRules,
      ?spec.rolePrompt,
      if (spec.skills.isNotEmpty) _skillsBlock(spec.skills),
      await environmentBlock(spec.workingDir),
    ];
    return parts.join('\n\n');
  }

  static String _skillsBlock(List<Map<String, Object?>> skills) {
    final out = StringBuffer(
      '<SKILLS>\nSkills are instructions for particular kinds of task. When a task matches one, read its SKILL.md '
      'first and follow it.\n',
    );
    for (final s in skills) {
      out.writeln('- ${s['name']}: ${s['description'] ?? ''} (${s['source'] ?? ''})');
    }
    out.write('</SKILLS>');
    return out.toString();
  }

  List<Map<String, Object?>> get _toolSpecs =>
      _forkTools ??
      [
        ...builtInToolSpecs(only: _spec.tools),
        for (final Map<String, Object?> t
            in _spec.clientTools ??
                (_spec.subagent
                    ? const <Map<String, Object?>>[]
                    : [for (final t in clientToolSpecs(held: true)) t['name'] == taskTool ? forkingTaskSpec() : t]))
          {
            'type': 'function',
            'function': {'name': t['name'], 'description': t['description'], 'parameters': t['parameters']},
          },
      ];

  // ------------------------------------------------------------ persistence

  void _append(Map<String, Object?> message) {
    _messages.add(message);
    File('${_dir.path}/messages.jsonl').writeAsStringSync('${jsonEncode(message)}\n', mode: FileMode.append);
  }

  void _rewriteMessages() =>
      File('${_dir.path}/messages.jsonl').writeAsStringSync(_messages.map((m) => '${jsonEncode(m)}\n').join());

  void _rewriteEvents() =>
      File('${_dir.path}/events.jsonl').writeAsStringSync(_history.map((e) => '${jsonEncode(e.raw)}\n').join());

  // ----------------------------------------------------------------- events

  @override
  Stream<HarnessEvent> get events {
    late final StreamController<HarnessEvent> c;
    c = StreamController<HarnessEvent>(
      onListen: () {
        _history.forEach(c.add);
        c.add(const ConnectionChange(connected: true));
        _listeners.add(c);
      },
      onCancel: () => _listeners.remove(c),
    );
    return c.stream;
  }

  String _newId() => const Uuid().v4();

  /// Emits an event built from agent-server-shaped [raw] JSON, and keeps it.
  HarnessEvent _emit(Map<String, Object?> raw) {
    raw['timestamp'] ??= DateTime.now().toIso8601String();
    final e = HarnessEvent.decode(raw);
    if (e is! StreamDelta) {
      _history.add(e);
      File('${_dir.path}/events.jsonl').writeAsStringSync('${jsonEncode(raw)}\n', mode: FileMode.append);
    }
    for (final c in [..._listeners]) {
      c.add(e);
    }
    return e;
  }

  void _delta({String content = '', String reasoning = ''}) {
    final e = StreamDelta(raw: const {}, content: content, reasoning: reasoning);
    for (final c in [..._listeners]) {
      c.add(e);
    }
  }

  void _setStatus(ExecutionStatus s) {
    if (status == s) return;
    status = s;
    _emit({'kind': 'ConversationStateUpdateEvent', 'id': _newId(), 'key': 'execution_status', 'value': s.wire});
  }

  // ------------------------------------------------------------------- API

  @override
  Future<void> send(String text, {bool run = true, List<String> images = const []}) async {
    final eid = _newId();
    final content = <Map<String, Object?>>[
      {'type': 'text', 'text': text},
      for (final url in images)
        {
          'type': 'image_url',
          'image_url': {'url': url},
        },
    ];
    _emit({
      'kind': 'MessageEvent',
      'id': eid,
      'source': 'user',
      'llm_message': {'role': 'user', 'content': content},
    });
    final message = {'role': 'user', 'content': images.isEmpty ? text : content, '_eid': eid};
    if (_looping) {
      // Steering: read before the next model call.
      _inbox.add(message);
      return;
    }
    _append(message);
    if (run) unawaited(_run());
  }

  @override
  Future<void> interrupt() async {
    _cancel?.complete();
    if (_decision case final d? when !d.isCompleted) d.complete((accept: false, reason: 'The user stopped this.'));
    _pauseRequested = true;
  }

  @override
  Future<void> pause() async {
    _pauseRequested = true;
    if (!_looping) _setStatus(ExecutionStatus.paused);
  }

  @override
  Future<void> resume() async {
    _pauseRequested = false;
    if (_looping) return;
    unawaited(_run());
  }

  @override
  Future<void> respond({required bool accept, String? reason}) async {
    final d = _decision;
    if (d == null || d.isCompleted) return;
    d.complete((accept: accept, reason: reason));
  }

  @override
  Future<void> setMode(AgentMode mode, {bool holdClientTools = false}) async {
    _spec = _withSpec(mode: mode);
    _writeSpec();
  }

  @override
  Future<void> switchLlm(SessionSpec spec) async {
    _spec = _withSpec(
      model: spec.model,
      effort: spec.effort,
      llmBaseUrl: spec.llmBaseUrl,
      llmApiKey: spec.llmApiKey,
      maxInputTokens: spec.maxInputTokens,
      vision: spec.vision,
    );
    _gateway = GatewayClient(baseUrl: _spec.llmBaseUrl, apiKey: _spec.llmApiKey);
    _tools = ToolRunner(root: _spec.workingDir, shell: _shell, gateway: _gateway, sessionTag: _spec.sessionTag);
    _writeSpec();
  }

  SessionSpec _withSpec({
    AgentMode? mode,
    String? model,
    String? effort,
    String? llmBaseUrl,
    String? llmApiKey,
    int? maxInputTokens,
    bool? vision,
  }) {
    final s = _spec;
    return SessionSpec(
      workingDir: s.workingDir,
      model: model ?? s.model,
      mode: mode ?? s.mode,
      llmBaseUrl: llmBaseUrl ?? s.llmBaseUrl,
      llmApiKey: llmApiKey ?? s.llmApiKey,
      sessionTag: s.sessionTag,
      maxInputTokens: maxInputTokens ?? s.maxInputTokens,
      maxOutputTokens: s.maxOutputTokens,
      vision: vision ?? s.vision,
      effort: effort ?? s.effort,
      holdClientTools: true,
      subagent: s.subagent,
      tools: s.tools,
      clientTools: s.clientTools,
      autoCompactAt: s.autoCompactAt,
    );
  }

  @override
  Future<void> rewindTo(String? head) async {
    if (_looping) throw const HarnessError('Stop the agent before rewinding.');
    final keep = <String>{};
    if (head != null) {
      for (final e in _history) {
        if (e.id.isNotEmpty) keep.add(e.id);
        if (e.id == head) break;
      }
    }
    _history.retainWhere((e) => e.id.isEmpty || keep.contains(e.id));
    _messages.retainWhere((m) => m['role'] == 'system' || keep.contains(m['_eid']));
    _trimDangling(_messages);
    _rewriteEvents();
    _rewriteMessages();
  }

  @override
  Future<void> close() async {
    // The session keeps running with no view open; only the listeners go.
    for (final c in [..._listeners]) {
      await c.close();
    }
    _listeners.clear();
  }

  @override
  Future<String> askAside(String question, {int maxTokens = 800}) async {
    final reply = await _gateway.complete(
      model: _spec.model,
      messages: [
        ..._outgoing(),
        {'role': 'user', 'content': question},
      ],
      // The same tools as the conversation keep the cached prefix; none may run.
      tools: _toolSpecs,
      toolChoice: 'none',
      sessionTag: _spec.sessionTag,
      effort: _spec.effort,
      maxTokens: maxTokens,
    );
    return reply.text;
  }

  /// Kills what the session's shell is still running.
  Future<void> killProcesses() => _shell.killAll();

  // ------------------------------------------------------------------ loop

  List<Map<String, Object?>> _outgoing() => [
    for (final m in _messages)
      if (m.containsKey('_eid')) (Map.of(m)..remove('_eid')) else m,
  ];

  Future<void> _run() async {
    if (_looping) return;
    _looping = true;
    _pauseRequested = false;
    var steps = 0;
    try {
      while (true) {
        for (final m in _inbox) {
          _append(m);
        }
        _inbox.clear();
        if (_pauseRequested) {
          _setStatus(ExecutionStatus.paused);
          return;
        }
        _setStatus(ExecutionStatus.running);
        await _maybeCompact();
        steps++;
        final wrapUp = steps > maxStepsPerRun;
        final cancel = _cancel = Completer<void>();
        final LlmReply reply;
        try {
          reply = await _gateway.complete(
            model: _spec.model,
            messages: [
              ..._outgoing(),
              if (wrapUp)
                {
                  'role': 'user',
                  'content':
                      'You have used this run\'s step budget. Stop calling tools and write your final message: '
                      'what you did, what is verified, and what is left.',
                },
            ],
            tools: _toolSpecs,
            toolChoice: wrapUp ? 'none' : null,
            sessionTag: _spec.sessionTag,
            effort: _spec.effort,
            maxTokens: _spec.maxOutputTokens,
            onText: (d) => _delta(content: d),
            onReasoning: (d) => _delta(reasoning: d),
            cancel: cancel.future,
          );
        } on LlmCancelled {
          _setStatus(ExecutionStatus.paused);
          return;
        }
        lastPromptTokens = reply.promptTokens;
        final textId = _newId();
        _append({...reply.toMessage(), '_eid': textId});
        // Always emitted (an empty one shows nothing): rewinds keep the
        // assistant turn by this event's id.
        _emit({
          'kind': 'MessageEvent',
          'id': textId,
          'source': 'agent',
          'llm_message': {'role': 'assistant', 'content': reply.text, 'reasoning_content': reply.reasoning},
        });
        if (reply.toolCalls.isEmpty || wrapUp) {
          if (_inbox.isNotEmpty) continue;
          _setStatus(ExecutionStatus.finished);
          return;
        }
        final stopped = await _handleCalls(reply.toolCalls, cancel);
        if (stopped) return;
      }
    } on LlmError catch (e) {
      _emit({'kind': 'ConversationErrorEvent', 'id': _newId(), 'detail': e.message});
      _setStatus(ExecutionStatus.error);
    } on Object catch (e) {
      _emit({'kind': 'ConversationErrorEvent', 'id': _newId(), 'detail': 'The agent loop failed: $e'});
      _setStatus(ExecutionStatus.error);
    } finally {
      _looping = false;
      _cancel = null;
    }
  }

  /// Compacts the history in place once the last call's input passed
  /// [SessionSpec.autoCompactAt] of the window: old tool output is pruned and
  /// the older span summarized by the session's own model; the newest turns
  /// stay word for word. The transcript shows it as "Context compacted".
  Future<void> _maybeCompact() async {
    final window = _spec.maxInputTokens ?? 0;
    if (window <= 0 || _spec.autoCompactAt <= 0 || lastPromptTokens < window * _spec.autoCompactAt) return;
    await compact();
  }

  /// Compacts now (auto-compact, or `/compact` with [focus]). False when
  /// there was nothing to summarize or the summary came back unusable.
  Future<bool> compact({String focus = ''}) async {
    final since = _history.lastIndexWhere((e) => e is ChatMessage && e.fromUser && splitCompacted(e.text) != null);
    final plan = planCompaction(_history.sublist(since < 0 ? 0 : since));
    if (plan == null) return false;
    final reply = await _gateway.raw({
      'model': _spec.model,
      'messages': summaryRequest(plan, focus: focus),
      'max_tokens': 6000,
    }, sessionTag: _spec.sessionTag);
    final text = switch (reply['choices']) {
      [{'message': {'content': final String c}}, ...] => c,
      _ => '',
    };
    final summary = cleanSummary(text);
    if (summary == null) return false;
    final message = continuationMessage(summary: summary, recent: renderTail(plan), resume: _looping);
    final eid = _newId();
    _emit({
      'kind': 'MessageEvent',
      'id': eid,
      'source': 'user',
      'llm_message': {'role': 'user', 'content': message},
    });
    final system = _messages.first;
    _messages
      ..clear()
      ..add(system)
      ..add({'role': 'user', 'content': message, '_eid': eid});
    _rewriteMessages();
    lastPromptTokens = 0;
    return true;
  }

  /// Shows [calls], waits for approval, runs them, and records the results.
  /// True when the run should stop (refused or interrupted).
  Future<bool> _handleCalls(List<LlmToolCall> calls, Completer<void> cancel) async {
    final waiting = <({LlmToolCall call, String actionId})>[];
    for (final call in calls) {
      final actionId = _newId();
      final args = call.args;
      _emit({
        'kind': 'ActionEvent',
        'id': actionId,
        'tool_name': call.name,
        'tool_call_id': call.id,
        'tool_call': {'name': call.name, 'arguments': call.arguments},
        'action': args == null ? {'kind': actionKinds[call.name] ?? ''} : actionFor(call.name, args, _spec.workingDir),
        'security_risk': 'UNKNOWN',
      });
      if (isFork && clientTools.contains(call.name)) {
        // A fork keeps the parent's tools (for the cache) but can't use these.
        _result(
          call,
          actionId,
          ToolOutput(
            'Error: a fork cannot use ${call.name}. Finish the task with your other tools and put everything in your '
            'final message.',
            isError: true,
          ),
        );
        continue;
      }
      if (args == null) {
        // A call cut off or garbled: never run, the model is told why.
        _result(
          call,
          actionId,
          ToolOutput(
            'Error: the arguments for ${call.name} were not valid JSON (the reply may have been cut off). Call it '
            'again with complete arguments; for a long file, write it in parts.',
            isError: true,
          ),
        );
        continue;
      }
      waiting.add((call: call, actionId: actionId));
    }
    if (waiting.isEmpty) return false;
    final decision = _decision = Completer();
    _setStatus(ExecutionStatus.waitingForConfirmation);
    final verdict = await decision.future;
    _decision = null;
    if (!verdict.accept) {
      final reason = verdict.reason ?? '';
      for (final w in waiting) {
        _emit({
          'kind': 'UserRejectObservation',
          'id': _newId(),
          'action_id': w.actionId,
          'tool_name': w.call.name,
          'rejection_reason': reason,
        });
        _messages.add({
          'role': 'tool',
          'tool_call_id': w.call.id,
          'content': reason.isEmpty ? 'The user declined this call.' : reason,
          '_eid': w.actionId,
        });
        File('${_dir.path}/messages.jsonl').writeAsStringSync('${jsonEncode(_messages.last)}\n', mode: FileMode.append);
      }
      // Parked like the agent-server: a refusal the app decided is followed
      // by resume(); the user's own "No" leaves it waiting for them.
      _setStatus(ExecutionStatus.paused);
      return true;
    }
    _setStatus(ExecutionStatus.running);
    // Calls that only look run together; the rest in order.
    var i = 0;
    while (i < waiting.length) {
      if (cancel.isCompleted) {
        for (final w in waiting.skip(i)) {
          _result(w.call, w.actionId, const ToolOutput('Not run: the user stopped the agent.', isError: true));
        }
        _setStatus(ExecutionStatus.paused);
        return true;
      }
      final batch = [waiting[i]];
      while (_readOnly(batch.last.call) &&
          i + batch.length < waiting.length &&
          _readOnly(waiting[i + batch.length].call)) {
        batch.add(waiting[i + batch.length]);
      }
      final outputs = await Future.wait([for (final w in batch) _execute(w.call, cancel.future)]);
      for (final (n, w) in batch.indexed) {
        _result(w.call, w.actionId, outputs[n]);
      }
      i += batch.length;
    }
    return false;
  }

  static const _readOnlyTools = {
    ToolNames.read,
    ToolNames.grep,
    ToolNames.glob,
    ToolNames.webFetch,
    ToolNames.webSearch,
    ToolNames.bashOutput,
  };

  bool _readOnly(LlmToolCall call) => _readOnlyTools.contains(call.name);

  Future<ToolOutput> _execute(LlmToolCall call, Future<void> cancel) async {
    if (actionKinds.containsKey(call.name)) return _tools.run(call.name, call.args!, cancel: cancel);
    // A client tool the app approved without answering it (present_files).
    return const ToolOutput('Shown to the user.');
  }

  void _result(LlmToolCall call, String actionId, ToolOutput out) {
    _emit({
      'kind': 'ObservationEvent',
      'id': _newId(),
      'action_id': actionId,
      'tool_name': call.name,
      'observation': {
        ...out.observation,
        'content': [
          {'type': 'text', 'text': out.text},
        ],
        'is_error': out.isError,
      },
    });
    _append({'role': 'tool', 'tool_call_id': call.id, 'content': out.text, '_eid': actionId});
  }
}
