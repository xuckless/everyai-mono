import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../domain/agent_mode.dart';
import '../settings/agent_prompt.dart';
import 'events.dart';
import 'harness.dart';

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

  OpenHandsHarness.located(this._locate, {http.Client? client}) : _http = client ?? http.Client();

  final AgentServerLocator _locate;
  final http.Client _http;

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
        'llm': {
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
        },
        'tools': [
          {'name': 'terminal'},
          {'name': 'file_editor'},
          {'name': 'task_tracker'},
          // `task` (subagents) fails to start in agent-server 1.59.0:
          // TaskTool.create() got an unexpected keyword argument 'conv_state'.
        ],
        'persona': ?spec.persona,
        'agent_context': {'system_message_suffix': spec.promptSuffix ?? workingRules},
      },
      'workspace': {'kind': 'LocalWorkspace', 'working_dir': spec.workingDir},
      'confirmation_policy': spec.mode.confirmationPolicy,
      'client_tools': [askUserQuestionSpec, presentPlanSpec],
      'initial_message': ?(first == null ? null : _message(first, run: true, images: spec.initialImages)),
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
    final WebSocketChannel socket;
    try {
      // Asked each time: the sidecar may have restarted on another port.
      final (base, key) = await _h._locate();
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
    _emit(const ConnectionChange(connected: true));
    _sub = socket.stream.listen(
      (frame) {
        _retries = 0;
        if (frame is! String) return;
        final event = HarnessEvent.decodeFrame(frame);
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

  /// Tells the listener and retries with backoff (0.3 s doubling to ~10 s).
  void _dropped() {
    if (_closed) return;
    _emit(const ConnectionChange(connected: false));
    final delay = Duration(milliseconds: 300 * (1 << _retries.clamp(0, 5)));
    _retries++;
    Timer(delay, _connect);
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
  Future<void> setMode(AgentMode mode) => _h._post('$_base/confirmation_policy', {'policy': mode.confirmationPolicy});

  @override
  Future<void> close() async {
    _closed = true;
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
