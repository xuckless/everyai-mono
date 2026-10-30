import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../domain/agent_mode.dart';
import '../events.dart';
import '../harness.dart';

/// Fills in what a device can't know when it starts a session on this host:
/// the persona, the project's rules and context, skills (see the remote
/// host's use). Gets the spec as the device sent it.
typedef SpecEnricher = Future<SessionSpec> Function(SessionSpec spec);

/// The EveryAI harness behind the agent-server's REST and event-socket
/// protocol (the subset `OpenHandsHarness` uses, see AGENTS.md), on
/// loopback with its own key. A paired device reaches it through the host
/// bridge exactly as it reaches the OpenHands sidecar, so remote sessions
/// run on the EveryAI harness without a protocol of their own.
final class AgentServerFacade {
  AgentServerFacade._(this._server, this.key, this._harness, this._enrich);

  final HttpServer _server;

  /// What callers send as `X-Session-API-Key` and in the socket's auth frame.
  final String key;
  final Harness _harness;
  final SpecEnricher? _enrich;

  /// The conversations started or opened here, for statuses and events.
  final _open = <String, HarnessSession>{};

  Uri get baseUrl => Uri.parse('http://127.0.0.1:${_server.port}/');

  static Future<AgentServerFacade> start(Harness harness, {SpecEnricher? enrich}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final random = Random.secure();
    final key = List.generate(32, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    final facade = AgentServerFacade._(server, key, harness, enrich);
    server.listen(facade._handle);
    return facade;
  }

  Future<void> close() => _server.close(force: true);

  Future<HarnessSession> _session(String id) async => _open[id] ??= await _harness.attach(id);

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path.replaceFirst(RegExp('^/'), '');
    if (path.startsWith('sockets/events/')) return _socket(req, path.substring('sockets/events/'.length));
    if (req.headers.value('X-Session-API-Key') != key) return _reply(req, 401, {'message': 'Wrong session key.'});
    try {
      final body = req.method == 'POST' ? await utf8.decoder.bind(req).join() : '';
      final json = body.isEmpty ? const <String, Object?>{} : jsonDecode(body) as Map<String, Object?>;
      final parts = path.split('/');
      if (parts.length < 2 || parts[0] != 'api' || parts[1] != 'conversations') {
        return await _reply(req, 404, {'message': 'Not found.'});
      }
      if (parts.length == 2) {
        if (req.method == 'POST') return await _reply(req, 200, {'id': await _start(json)});
        final ids = req.uri.queryParametersAll['ids'] ?? const [];
        final statuses = await _harness.statuses(ids);
        return await _reply(req, 200, [
          for (final MapEntry(:key, :value) in statuses.entries) {'id': key, 'execution_status': value.wire},
        ]);
      }
      final id = parts[2];
      final session = await _session(id);
      final action = parts.skip(3).join('/');
      switch ((req.method, action)) {
        case ('GET', ''):
          final status = (await _harness.statuses([id]))[id] ?? ExecutionStatus.idle;
          return await _reply(req, 200, {
            'id': id,
            'execution_status': status.wire,
            'workspace': {'working_dir': _dirs[id] ?? ''},
          });
        case ('GET', 'events/search'):
          final items = <Object?>[];
          final sub = session.events.listen((e) {
            if (e.id.isNotEmpty) items.add(e.raw);
          });
          await Future<void>.delayed(Duration.zero);
          await sub.cancel();
          return await _reply(req, 200, {'items': items, 'next_page_id': null});
        case ('POST', 'events'):
          final (text, images) = _messageOf(json);
          await session.send(text, run: json['run'] != false, images: images);
        case ('POST', 'interrupt'):
          await session.interrupt();
        case ('POST', 'pause'):
          await session.pause();
        case ('POST', 'run'):
          await session.resume();
        case ('POST', 'events/respond_to_confirmation'):
          await session.respond(accept: json['accept'] == true, reason: json['reason'] as String?);
        case ('POST', 'confirmation_policy'):
          break;
        case ('POST', 'switch_llm'):
          await session.switchLlm(
            _specOf({
              'agent': {'llm': json['llm']},
            }, workingDir: _dirs[id] ?? ''),
          );
        case ('POST', 'navigate'):
          await session.rewindTo(json['event_id'] as String?);
        default:
          return await _reply(req, 404, {'message': 'Not supported here.'});
      }
      return await _reply(req, 200, {'success': true});
    } on Object catch (e) {
      return _reply(req, 500, {'message': '$e'});
    }
  }

  /// Folders by conversation, for `GET api/conversations/{id}`.
  final _dirs = <String, String>{};

  Future<String> _start(Map<String, Object?> body) async {
    final dir = switch (body['workspace']) {
      {'working_dir': final String d} => d,
      _ => throw const FormatException('workspace.working_dir is required'),
    };
    var spec = _specOf(body, workingDir: dir);
    if (_enrich case final enrich?) spec = await enrich(spec);
    final session = await _harness.start(spec);
    _open[session.id] = session;
    _dirs[session.id] = dir;
    return session.id;
  }

  static (String, List<String>) _messageOf(Map<String, Object?> m) {
    final text = StringBuffer();
    final images = <String>[];
    for (final part in m['content'] as List<Object?>? ?? const []) {
      switch (part) {
        case {'type': 'text', 'text': final String t}:
          text.write(t);
        case {'type': 'image', 'image_urls': final List<Object?> urls}:
          images.addAll(urls.whereType<String>());
      }
    }
    return (text.toString(), images);
  }

  /// The agent-server's conversation body as a [SessionSpec].
  static SessionSpec _specOf(Map<String, Object?> body, {required String workingDir}) {
    final agent = body['agent'] as Map<String, Object?>? ?? const {};
    final llm = agent['llm'] as Map<String, Object?>? ?? const {};
    final headers = llm['extra_headers'] as Map<String, Object?>? ?? const {};
    final context = agent['agent_context'] as Map<String, Object?>? ?? const {};
    final first = body['initial_message'] as Map<String, Object?>?;
    final (text, images) = first == null ? ('', <String>[]) : _messageOf(first);
    final model = llm['model'] as String? ?? '';
    final clientTools = (body['client_tools'] as List<Object?>?)?.cast<Map<String, Object?>>();
    return SessionSpec(
      workingDir: workingDir,
      model: model.startsWith('openai/') ? model.substring('openai/'.length) : model,
      mode: AgentMode.ask,
      llmBaseUrl: llm['base_url'] as String? ?? '',
      llmApiKey: llm['api_key'] as String? ?? '',
      sessionTag: headers['X-EveryAI-Session'] as String? ?? llm['usage_id'] as String? ?? '',
      effort: headers['X-EveryAI-Effort'] as String? ?? llm['reasoning_effort'] as String?,
      maxInputTokens: (llm['max_input_tokens'] as num?)?.toInt(),
      maxOutputTokens: (llm['max_output_tokens'] as num?)?.toInt() ?? 64000,
      vision: llm['capability_overrides'] is Map,
      persona: agent['persona'] as String?,
      // Already worded for the session (subagent rules, held answers included).
      promptSuffix: context['system_message_suffix'] as String?,
      skills: (context['skills'] as List<Object?>?)?.cast<Map<String, Object?>>() ?? const [],
      tools: [
        for (final t in agent['tools'] as List<Object?>? ?? const [])
          if (t case {'name': final String n}) n,
      ],
      clientTools: clientTools,
      holdClientTools: true,
      initialMessage: first == null ? null : text,
      initialImages: images,
      runInitial: first?['run'] != false,
    );
  }

  Future<void> _socket(HttpRequest req, String id) async {
    if (!WebSocketTransformer.isUpgradeRequest(req)) return _reply(req, 400, {'message': 'Expected a WebSocket.'});
    final socket = await WebSocketTransformer.upgrade(req);
    StreamSubscription<HarnessEvent>? events;
    socket.listen((frame) async {
      if (events != null || frame is! String) return;
      final auth = jsonDecode(frame);
      if (auth is! Map || auth['session_api_key'] != key) {
        await socket.close(4001, 'Wrong session key.');
        return;
      }
      try {
        final session = await _session(id);
        events = session.events.listen((e) {
          if (e is ConnectionChange) return;
          socket.add(jsonEncode(e is StreamDelta ? _delta(e) : e.raw));
        });
      } on Object catch (e) {
        await socket.close(4004, '$e');
      }
    }, onDone: () => events?.cancel());
  }

  static Map<String, Object?> _delta(StreamDelta e) => {
    'kind': 'StreamingDeltaEvent',
    'content': e.content,
    'reasoning_content': e.reasoning,
    if (e.tool case final t?) 'tool': t.toJson(),
  };

  static Future<void> _reply(HttpRequest req, int status, Object body) async {
    req.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await req.response.close();
  }
}
