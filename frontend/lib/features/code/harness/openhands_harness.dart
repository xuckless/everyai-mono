import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../domain/agent_mode.dart';
import '../domain/rewind.dart';
import '../domain/subagents.dart' show subagentRules;
import '../settings/agent_prompt.dart';
import 'events.dart';
import 'harness.dart';
import 'session_processes.dart';

/// Where the agent-server listens and its session key. Asked again before
/// every request and reconnect, so a restarted sidecar (new port, new key)
/// is picked up.
typedef AgentServerLocator = Future<(Uri baseUrl, String sessionApiKey)> Function();

/// The OpenHands agent-server (the local sidecar): REST under `/api`, events
/// over `/sockets/events/{id}`. See AGENTS.md for the protocol.
final class OpenHandsHarness implements Harness {
  /// A server at a fixed address.
  OpenHandsHarness({required Uri baseUrl, required String sessionApiKey, http.Client? client})
    : this.located(() async => (baseUrl, sessionApiKey), client: client);

  /// [restarts] fires when the server came back after a crash; sessions
  /// waiting to reconnect do so at once.
  OpenHandsHarness.located(this._locate, {http.Client? client, Stream<void>? restarts})
    : _http = client ?? http.Client(),
      _restarts = restarts ?? const Stream.empty();

  final AgentServerLocator _locate;
  final http.Client _http;
  final Stream<void> _restarts;

  Future<Object?> _request(String method, String path, [Object? body]) async {
    final (base, key) = await _locate();
    final req = http.Request(method, base.resolve(path))
      ..headers.addAll({'X-Session-API-Key': key, 'Content-Type': 'application/json'});
    if (body != null || method == 'POST') req.body = jsonEncode(body ?? const {});
    final res = await http.Response.fromStream(await _http.send(req));
    if (res.statusCode >= 300) throw HarnessError('${res.statusCode} ${res.body}', status: res.statusCode);
    return res.body.isEmpty ? null : jsonDecode(res.body);
  }

  Future<Object?> _post(String path, [Object? body]) => _request('POST', path, body);

  @override
  Future<HarnessSession> start(SessionSpec spec) async {
    final first = spec.initialMessage;
    final info = await _post('api/conversations', {
      'agent': {
        'kind': 'Agent',
        'llm': llmConfig(spec),
        'tools': [
          {
            'name': 'terminal',
            // Tags what the terminal starts, so Stop can end the session's
            // leftover processes (see killSessionProcesses). The protocol has
            // no hard time limit: a command past its timeout keeps running.
            'params': {
              'env': {sessionEnvVar: spec.sessionTag},
            },
          },
          {'name': 'file_editor'},
          {'name': 'task_tracker'},
          // OpenHands' own `task` (subagents) fails to start in agent-server
          // 1.59.0 (TaskTool.create() got an unexpected keyword argument
          // 'conv_state'). Our `run_subagent` client tool runs child
          // conversations instead; a client tool can't be called `task`
          // (the server rejects names that collide with its built-ins).
        ].where((t) => spec.tools?.contains(t['name']) ?? true).toList(),
        // MCP servers the user set up and approved; the agent-server starts
        // and talks to them, and their tools arrive as MCPToolAction.
        if (spec.mcpConfig.isNotEmpty && (spec.tools?.contains('mcp') ?? true)) 'mcp_config': spec.mcpConfig,
        'persona': ?spec.persona,
        'agent_context': {'system_message_suffix': _suffix(spec), if (spec.skills.isNotEmpty) 'skills': spec.skills},
      },
      'workspace': {'kind': 'LocalWorkspace', 'working_dir': spec.workingDir},
      'confirmation_policy': spec.mode.confirmationPolicy(holdClientTools: spec.holdClientTools),
      // Subagents get none: they can't ask the user, and depth stays at 1.
      'client_tools':
          spec.clientTools ?? (spec.subagent ? const <Object?>[] : clientToolSpecs(held: spec.holdClientTools)),
      'initial_message': ?(first == null ? null : _message(first, run: spec.runInitial, images: spec.initialImages)),
    });
    final id = (info as Map<String, Object?>?)?['id'] as String?;
    if (id == null) throw const HarnessError('The agent server returned no conversation id.');
    return attach(id);
  }

  @override
  Future<HarnessSession> attach(String conversationId) async {
    // A missing conversation would only show as a socket that keeps closing.
    try {
      await _request('GET', 'api/conversations/$conversationId');
    } on HarnessError catch (e) {
      if (e.status == 404) {
        throw const HarnessError(
          "This session's history is no longer on the agent server, so it can't be resumed.",
          status: 404,
        );
      }
      rethrow;
    }
    final session = _OpenHandsSession(this, conversationId);
    session._restartSub = _restarts.listen((_) => session._reconnectNow());
    unawaited(session._connect());
    return session;
  }

  @override
  Future<Map<String, ExecutionStatus>> statuses(List<String> conversationIds) async {
    if (conversationIds.isEmpty) return const {};
    final query = conversationIds.map((id) => 'ids=${Uri.encodeQueryComponent(id)}').join('&');
    final list = await _request('GET', 'api/conversations?$query');
    return {
      for (final c in (list as List<Object?>? ?? const []))
        if (c case {'id': final String id, 'execution_status': final String status}) id: ExecutionStatus.parse(status),
    };
  }

  /// The agent's `llm` for [spec]: at conversation start and on `switch_llm`.
  static Map<String, Object?> llmConfig(SessionSpec spec) => {
    // LiteLLM routes "openai/…" to an OpenAI-compatible base_url; the
    // gateway strips the prefix.
    'model': 'openai/${spec.model}',
    'base_url': spec.llmBaseUrl,
    'api_key': spec.llmApiKey,
    'usage_id': spec.sessionTag,
    // LiteLLM drops reasoning_effort for models it doesn't know; the
    // gateway applies the header instead.
    'extra_headers': {'X-EveryAI-Session': spec.sessionTag, 'X-EveryAI-Effort': ?spec.effort},
    'reasoning_effort': ?spec.effort,
    'max_input_tokens': ?spec.maxInputTokens,
    // OpenHands caps models it doesn't know at 16,384 output tokens;
    // thinking plus one whole-file edit runs past that and the tool
    // call gets cut off.
    'max_output_tokens': spec.maxOutputTokens,
    // LiteLLM doesn't know our gateway's models; without this images are dropped.
    if (spec.vision) 'capability_overrides': {'supports_vision': true},
  };

  static String _suffix(SessionSpec spec) {
    final suffix = spec.promptSuffix ?? workingRules;
    if (spec.subagent) return '$suffix\n\n$subagentRules${spec.rolePrompt == null ? '' : '\n\n${spec.rolePrompt}'}';
    return spec.holdClientTools ? forHeldClientTools(suffix) : suffix;
  }

  static Map<String, Object?> _message(String text, {required bool run, List<String> images = const []}) => {
    'role': 'user',
    'content': [
      {'type': 'text', 'text': text},
      if (images.isNotEmpty) {'type': 'image', 'image_urls': images},
    ],
    'run': run,
  };
}

final class _OpenHandsSession implements HarnessSession {
  _OpenHandsSession(this._h, this.id);

  final OpenHandsHarness _h;
  @override
  final String id;

  /// Everything received so far (not streaming deltas), replayed to each new
  /// listener: a session started before its view opens loses nothing.
  final _history = <HarnessEvent>[];
  final _listeners = <StreamController<HarnessEvent>>{};
  bool? _connected;
  final _seen = <String>{};
  WebSocketChannel? _socket;
  StreamSubscription<Object?>? _sub;
  bool _closed = false;
  int _retries = 0;
  Timer? _retry;
  StreamSubscription<void>? _restartSub;

  /// The server ("base key") the socket last connected to; another one means it restarted.
  String? _server;

  /// Events on branches a rewind abandoned: the socket's replay still sends them.
  final _offBranch = <String>{};
  bool _branchRead = false;

  @override
  Stream<HarnessEvent> get events {
    late final StreamController<HarnessEvent> c;
    c = StreamController<HarnessEvent>(
      onListen: () {
        _history.forEach(c.add);
        if (_connected case final connected?) c.add(ConnectionChange(connected: connected));
        _listeners.add(c);
      },
      onCancel: () => _listeners.remove(c),
    );
    return c.stream;
  }

  Future<void> _connect() async {
    if (_closed) return;
    _retry?.cancel();
    _retry = null;
    final WebSocketChannel socket;
    String? server;
    try {
      // Asked each time: the sidecar may have restarted on another port.
      await _readBranch();
      final (base, key) = await _h._locate();
      server = '$base $key';
      final ws = base.replace(
        scheme: base.scheme == 'https' ? 'wss' : 'ws',
        path: '${base.path.replaceAll(RegExp(r'/$'), '')}/sockets/events/$id',
        queryParameters: {'resend_mode': 'all'},
      );
      socket = _socket = WebSocketChannel.connect(ws);
      await socket.ready;
      socket.sink.add(jsonEncode({'type': 'auth', 'session_api_key': key}));
    } on Object {
      _dropped();
      return;
    }
    if (_closed) {
      unawaited(socket.sink.close());
      return;
    }
    final restarted = _server != null && _server != server;
    _server = server;
    _emit(ConnectionChange(connected: true, restarted: restarted));
    _sub = socket.stream.listen(
      (frame) {
        _retries = 0;
        if (frame is! String) return;
        final event = HarnessEvent.decodeFrame(frame);
        if (event.id.isNotEmpty && _offBranch.contains(event.id)) return;
        // Reconnects resend history; skip what we already have.
        if (event.id.isNotEmpty && !_seen.add(event.id)) return;
        _emit(event);
      },
      onError: (_) {},
      onDone: _dropped,
    );
  }

  void _emit(HarnessEvent e) {
    if (_closed) return;
    switch (e) {
      case ConnectionChange(:final connected):
        _connected = connected;
      case StreamDelta():
        break;
      default:
        _history.add(e);
    }
    for (final c in [..._listeners]) {
      c.add(e);
    }
  }

  /// Before the first replay: which stored events are off the active branch
  /// (the conversation was rewound earlier). Best effort; without it the
  /// abandoned turns show too.
  Future<void> _readBranch() async {
    if (_branchRead) return;
    _branchRead = true;
    try {
      final info = await _h._request('GET', _base);
      final leaf = info is Map<String, Object?> ? info['leaf_event_id'] as String? : null;
      if (leaf == null) return;
      final events = <HarnessEvent>[];
      String? page;
      do {
        final query = page == null ? '' : '&page_id=${Uri.encodeQueryComponent(page)}';
        final res = await _h._request('GET', '$_base/events/search?limit=100$query');
        if (res is! Map<String, Object?>) break;
        for (final item in res['items'] as List<Object?>? ?? const []) {
          if (item is Map<String, Object?>) events.add(HarnessEvent.decode(item));
        }
        page = res['next_page_id'] as String?;
      } while (page != null);
      _offBranch.addAll(offBranch(events, leaf));
    } on Object {
      return;
    }
  }

  /// Tells the listener and retries with backoff (0.3 s doubling to ~10 s).
  void _dropped() {
    if (_closed) return;
    _emit(const ConnectionChange(connected: false));
    final delay = Duration(milliseconds: 300 * (1 << _retries.clamp(0, 5)));
    _retries++;
    _retry = Timer(delay, _connect);
  }

  /// The server is back: skip the rest of the backoff.
  void _reconnectNow() {
    if (_closed || _retry == null) return;
    _retries = 0;
    unawaited(_connect());
  }

  String get _base => 'api/conversations/$id';

  @override
  Future<void> send(String text, {bool run = true, List<String> images = const []}) =>
      _h._post('$_base/events', OpenHandsHarness._message(text, run: run, images: images));

  @override
  Future<void> interrupt() => _h._post('$_base/interrupt');

  @override
  Future<void> pause() => _h._post('$_base/pause');

  @override
  Future<void> resume() => _h._post('$_base/run');

  @override
  Future<void> respond({required bool accept, String? reason}) =>
      _h._post('$_base/events/respond_to_confirmation', {'accept': accept, 'reason': ?reason});

  @override
  Future<void> setMode(AgentMode mode, {bool holdClientTools = false}) =>
      _h._post('$_base/confirmation_policy', {'policy': mode.confirmationPolicy(holdClientTools: holdClientTools)});

  @override
  Future<void> switchLlm(SessionSpec spec) => _h._post('$_base/switch_llm', {'llm': OpenHandsHarness.llmConfig(spec)});

  @override
  Future<void> rewindTo(String? head) async {
    await _h._post('$_base/navigate', {'event_id': head});
    final kept = {for (final e in rewound(_history, head)) e.id};
    for (final e in _history) {
      if (!kept.contains(e.id)) _offBranch.add(e.id);
    }
    _history.retainWhere((e) => kept.contains(e.id));
  }

  @override
  Future<void> close() async {
    _closed = true;
    _retry?.cancel();
    await _restartSub?.cancel();
    await _sub?.cancel();
    await _socket?.sink.close();
    for (final c in [..._listeners]) {
      await c.close();
    }
    _listeners.clear();
  }
}

final class HarnessError implements Exception {
  const HarnessError(this.message, {this.status});
  final String message;

  /// The HTTP status, for server errors.
  final int? status;

  @override
  String toString() => message;
}
