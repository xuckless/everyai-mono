// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../domain/local_server.dart';
import 'local_http.dart';

/// The ports local servers listen on by default. A server is told apart by its answers, not its port: llama.cpp and
/// MLX both use 8080 (so does our own dev backend), and anyone can move any of them.
const defaultLocalPorts = <int>[11434, 1234, 8080, 1337, 8000];

/// What answers on `http://127.0.0.1:<port>`, or null when nothing does (or it's our own backend).
Future<LocalServer?> identifyServer(LocalHttp http, int port, {String host = '127.0.0.1'}) async {
  final root = Uri.parse('http://$host:$port');
  Uri at(String path) => root.replace(path: path);
  LocalServer found(LocalServerKind kind) =>
      LocalServer(id: kind.name, kind: kind, label: kind.label, baseUrl: '${root.toString()}/v1');

  final version = await http.get(at('/api/version'));
  if (version != null && version.ok && version.json?['version'] is String) {
    final tags = await http.get(at('/api/tags'));
    if (tags != null && tags.ok && tags.json?['models'] is List) return found(LocalServerKind.ollama);
  }
  final ping = await http.get(at('/v1/ping'));
  if (ping != null && ping.ok && ping.json?['service'] == 'everyai-backend-exp') return null;
  final lms = await http.get(at('/api/v0/models'));
  if (lms != null && lms.ok && lms.json?['data'] is List) return found(LocalServerKind.lmstudio);
  final props = await http.get(at('/props'));
  final p = props != null && props.ok ? props.json : null;
  if (p != null && (p.containsKey('default_generation_settings') || p.containsKey('total_slots'))) {
    return found(LocalServerKind.llamacpp);
  }
  final models = await http.get(at('/v1/models'));
  final Object? data = models == null || !models.ok ? null : models.json?['data'];
  if (data is! List) return null;
  final first = data.whereType<Map<String, Object?>>().firstOrNull;
  if (first != null && (first['owned_by'] == 'vllm' || first.containsKey('max_model_len'))) {
    return found(LocalServerKind.vllm);
  }
  if (data.whereType<Map<String, Object?>>().any((m) => m['id'] == 'system' || m['id'] == 'pcc')) {
    return found(LocalServerKind.fm);
  }
  // A plain OpenAI-compatible server: named after the app that uses this port by default.
  return switch (port) {
    1337 => found(LocalServerKind.jan),
    8080 => found(LocalServerKind.mlx),
    _ => LocalServer(
      id: 'openai:$port',
      kind: LocalServerKind.custom,
      label: 'Server on port $port',
      baseUrl: '${root.toString()}/v1',
    ),
  };
}

/// Every server on [ports], in port order, one per kind (the first wins).
Future<List<LocalServer>> scanLocalPorts(LocalHttp http, {List<int> ports = defaultLocalPorts}) async {
  final found = await Future.wait([for (final p in ports) identifyServer(http, p)]);
  final out = <LocalServer>[];
  for (final s in found) {
    if (s != null && !out.any((o) => o.id == s.id)) out.add(s);
  }
  return out;
}

/// The context we assume when a server doesn't say.
const assumedContext = 8192;

/// The models [server] serves now (embedding-only models left out).
Future<List<LocalModel>> listServerModels(LocalHttp http, LocalServer server) async {
  final base = Uri.parse(server.baseUrl);
  final root = base.replace(path: base.path.replaceFirst(RegExp(r'/v1$'), ''));
  Uri at(String path) => root.replace(path: '${root.path}$path');
  final auth = {if (server.apiKey case final k? when k.isNotEmpty) 'Authorization': 'Bearer $k'};
  switch (server.kind) {
    case LocalServerKind.ollama:
      final tags = await http.get(at('/api/tags'));
      final list = tags?.json?['models'];
      if (list is! List) return const [];
      final out = <LocalModel>[];
      for (final m in list.whereType<Map<String, Object?>>()) {
        final name = m['name'] as String? ?? m['model'] as String?;
        if (name == null || _embedding(name)) continue;
        final show = await http.send(
          'POST',
          at('/api/show'),
          json: {'model': name},
          timeout: const Duration(seconds: 4),
        );
        out.add(ollamaModel(name, server.id, show?.json, size: (m['size'] as num?)?.toInt()));
      }
      return out;
    case LocalServerKind.lmstudio:
      final res = await http.get(at('/api/v0/models'));
      final data = res?.json?['data'];
      if (data is! List) return const [];
      return [
        for (final m in data.whereType<Map<String, Object?>>())
          if (m['id'] is String && m['type'] != 'embeddings' && !_embedding(m['id'] as String))
            LocalModel(
              name: m['id'] as String,
              serverId: server.id,
              contextTokens: (m['max_context_length'] as num?)?.toInt() ?? assumedContext,
              contextGuessed: m['max_context_length'] is! num,
              tools: (m['capabilities'] is List && (m['capabilities'] as List).contains('tool_use')),
              vision: m['type'] == 'vlm',
            ),
      ];
    case LocalServerKind.llamacpp:
      final props = (await http.get(at('/props')))?.json;
      final settings = props?['default_generation_settings'];
      final ctx = settings is Map ? (settings['n_ctx'] as num?)?.toInt() : null;
      final modalities = props?['modalities'];
      final template = props?['chat_template'];
      return [
        for (final id in await _openAiIds(http, server, auth))
          LocalModel(
            name: id,
            serverId: server.id,
            contextTokens: ctx ?? assumedContext,
            contextGuessed: ctx == null,
            tools: template is String && template.contains('tool'),
            vision: modalities is Map && modalities['vision'] == true,
          ),
      ];
    case LocalServerKind.fm:
      final res = await http.get(Uri.parse('${server.baseUrl}/models'));
      final data = res?.json?['data'];
      if (data is! List) return const [];
      return [
        for (final m in data.whereType<Map<String, Object?>>())
          if (m['id'] is String)
            LocalModel(
              name: m['id'] as String,
              serverId: server.id,
              contextTokens: _contextOf(m) ?? fmAssumedContext,
              contextGuessed: _contextOf(m) == null,
              tools: true,
            ),
      ];
    case LocalServerKind.jan || LocalServerKind.vllm || LocalServerKind.mlx || LocalServerKind.custom:
      final res = await http.get(Uri.parse('${server.baseUrl}/models'), headers: auth);
      final data = res?.json?['data'];
      if (data is! List) return const [];
      return [
        for (final m in data.whereType<Map<String, Object?>>())
          if (m['id'] is String && !_embedding(m['id'] as String))
            LocalModel(
              name: m['id'] as String,
              serverId: server.id,
              contextTokens: _contextOf(m) ?? assumedContext,
              contextGuessed: _contextOf(m) == null,
              // Most OpenAI-compatible servers take tool definitions; the model decides whether it uses them.
              tools: true,
            ),
      ];
  }
}

/// Apple's on-device model's window when `fm` doesn't say (its 2025 release had 4096 tokens).
const fmAssumedContext = 4096;

/// One Ollama model from its `/api/show` answer: `capabilities` (`tools`, `vision`, `thinking`) and
/// `model_info["<arch>.context_length"]`.
LocalModel ollamaModel(String name, String serverId, Map<String, Object?>? show, {int? size}) {
  final caps = show?['capabilities'];
  final capSet = caps is List ? caps.whereType<String>().toSet() : const <String>{};
  int? ctx;
  final info = show?['model_info'];
  if (info is Map) {
    for (final MapEntry(:key, :value) in info.entries) {
      if (key is String && key.endsWith('.context_length') && value is num) ctx = value.toInt();
    }
  }
  return LocalModel(
    name: name,
    serverId: serverId,
    contextTokens: ctx ?? assumedContext,
    contextGuessed: ctx == null,
    tools: capSet.contains('tools'),
    vision: capSet.contains('vision'),
    reasoning: capSet.contains('thinking'),
    sizeBytes: size,
  );
}

Future<List<String>> _openAiIds(LocalHttp http, LocalServer server, Map<String, String> auth) async {
  final data = (await http.get(Uri.parse('${server.baseUrl}/models'), headers: auth))?.json?['data'];
  if (data is! List) return const [];
  return [
    for (final m in data.whereType<Map<String, Object?>>())
      if (m['id'] is String) m['id'] as String,
  ];
}

int? _contextOf(Map<String, Object?> m) {
  for (final k in const ['context_length', 'context_window', 'max_model_len', 'max_context_length']) {
    if (m[k] case final num v) return v.toInt();
  }
  return null;
}

bool _embedding(String name) {
  final n = name.toLowerCase();
  return n.contains('embed') || n.contains('rerank');
}

/// Whether a manual server answers: its model list, or the reason it doesn't.
Future<({List<LocalModel> models, String? problem})> testServer(LocalHttp http, LocalServer server) async {
  final auth = {if (server.apiKey case final k? when k.isNotEmpty) 'Authorization': 'Bearer $k'};
  final res = await http.get(Uri.parse('${server.baseUrl}/models'), headers: auth, timeout: const Duration(seconds: 4));
  if (res == null) return (models: const <LocalModel>[], problem: 'Nothing answered at ${server.baseUrl}');
  if (res.status == 401 || res.status == 403) return (models: const <LocalModel>[], problem: 'The key was refused');
  if (!res.ok || res.json?['data'] is! List) {
    return (models: const <LocalModel>[], problem: 'It answered, but not like an OpenAI-compatible server');
  }
  return (models: await listServerModels(http, server), problem: null);
}
