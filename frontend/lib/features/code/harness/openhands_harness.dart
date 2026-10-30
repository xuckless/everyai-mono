import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../domain/agent_mode.dart';
import 'events.dart';
import 'harness.dart';

/// The OpenHands agent-server (the local sidecar): REST under `/api`, events
/// over `/sockets/events/{id}`. See AGENTS.md for the protocol.
final class OpenHandsHarness implements Harness {
  OpenHandsHarness({required this.baseUrl, required this.sessionApiKey, http.Client? client})
    : _http = client ?? http.Client();

  final Uri baseUrl;
  final String sessionApiKey;
  final http.Client _http;

  Map<String, String> get _headers => {'X-Session-API-Key': sessionApiKey, 'Content-Type': 'application/json'};

  Future<Object?> _post(String path, [Object? body]) async {
    final res = await _http.post(baseUrl.resolve(path), headers: _headers, body: jsonEncode(body ?? const {}));
    if (res.statusCode >= 300) throw HarnessError('${res.statusCode} ${res.body}');
    return res.body.isEmpty ? null : jsonDecode(res.body);
  }

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
          'extra_headers': {'X-EveryAI-Session': spec.sessionTag},
        },
        'tools': [
          {'name': 'terminal'},
          {'name': 'file_editor'},
          {'name': 'task_tracker'},
          {'name': 'task'},
        ],
      },
      'workspace': {'kind': 'LocalWorkspace', 'working_dir': spec.workingDir},
      'confirmation_policy': spec.mode.confirmationPolicy,
      'client_tools': [askUserQuestionSpec],
      'initial_message': ?(first == null ? null : _message(_withMode(first, spec.mode), run: true)),
    });
    final id = (info as Map<String, Object?>?)?['id'] as String?;
    if (id == null) throw const HarnessError('The agent server returned no conversation id.');
    return attach(id);
  }

  @override
  Future<HarnessSession> attach(String conversationId) async {
    final session = _OpenHandsSession(this, conversationId);
    session._connect();
    return session;
  }

  static Map<String, Object?> _message(String text, {required bool run}) => {
    'role': 'user',
    'content': [
      {'type': 'text', 'text': text},
    ],
    'run': run,
  };

  static String _withMode(String text, AgentMode mode) => mode == AgentMode.plan ? '${mode.planPrompt}\n\n$text' : text;
}

final class _OpenHandsSession implements HarnessSession {
  _OpenHandsSession(this._h, this.id);

  final OpenHandsHarness _h;
  @override
  final String id;

  final _events = StreamController<HarnessEvent>.broadcast();
  final _seen = <String>{};
  WebSocketChannel? _socket;
  StreamSubscription<Object?>? _sub;
  bool _closed = false;
  int _retries = 0;

  @override
  Stream<HarnessEvent> get events => _events.stream;

  void _connect() {
    if (_closed) return;
    final ws = _h.baseUrl.replace(
      scheme: _h.baseUrl.scheme == 'https' ? 'wss' : 'ws',
      path: '${_h.baseUrl.path.replaceAll(RegExp(r'/$'), '')}/sockets/events/$id',
      queryParameters: {'resend_mode': 'all'},
    );
    final socket = _socket = WebSocketChannel.connect(ws);
    socket.sink.add(jsonEncode({'type': 'auth', 'session_api_key': _h.sessionApiKey}));
    _sub = socket.stream.listen(
      (frame) {
        _retries = 0;
        if (frame is! String) return;
        final event = HarnessEvent.decodeFrame(frame);
        // Reconnects resend history; skip what we already have.
        if (event.id.isNotEmpty && !_seen.add(event.id)) return;
        _events.add(event);
      },
      onError: (_) {},
      onDone: () {
        if (_closed) return;
        final delay = Duration(milliseconds: 300 * (1 << _retries.clamp(0, 5)));
        _retries++;
        Timer(delay, _connect);
      },
    );
  }

  String get _base => 'api/conversations/$id';

  @override
  Future<void> send(String text, {bool run = true}) =>
      _h._post('$_base/events', OpenHandsHarness._message(text, run: run));

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
    await _events.close();
  }
}

final class HarnessError implements Exception {
  const HarnessError(this.message);
  final String message;
  @override
  String toString() => 'HarnessError: $message';
}
