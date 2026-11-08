// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/foundation.dart';

import '../../../core/net/api_client.dart';
import '../domain/local_server.dart';

/// Where a model is on its server, as the bundled EveryAI server tracks it (backend-exp `local_models.zig`, the
/// same five states and transitions): unloaded → loading → loaded → unloading → unloaded; a load or unload that
/// fails → failed (with the reason), from which either can be tried again.
enum ModelLoad {
  unloaded,
  loading,
  loaded,
  unloading,
  failed;

  static ModelLoad parse(Object? v) => values.where((s) => s.name == v).firstOrNull ?? ModelLoad.unloaded;

  /// Load and Unload are off while the server works on one.
  bool get busy => this == loading || this == unloading;
}

/// One model's state on one server.
@immutable
final class ModelLoadState {
  const ModelLoadState({
    required this.kind,
    required this.baseUrl,
    required this.name,
    required this.state,
    this.ours = false,
    this.reason,
    this.controllable = false,
  });

  factory ModelLoadState.fromJson(Map<String, Object?> j) => ModelLoadState(
    kind: j['kind'] as String? ?? '',
    baseUrl: j['base_url'] as String? ?? '',
    name: j['name'] as String? ?? '',
    state: ModelLoad.parse(j['state']),
    ours: j['ours'] == true,
    reason: j['reason'] as String?,
    controllable: j['controllable'] == true,
  );

  final String kind;
  final String baseUrl;
  final String name;
  final ModelLoad state;

  /// EveryAI loaded it: it is unloaded when EveryAI quits.
  final bool ours;
  final String? reason;

  /// The server lets EveryAI load and unload it (Ollama, LM Studio); others keep their models loaded themselves.
  final bool controllable;

  String get key => '$baseUrl|$name';

  @override
  bool operator ==(Object other) =>
      other is ModelLoadState &&
      other.kind == kind &&
      other.baseUrl == baseUrl &&
      other.name == name &&
      other.state == state &&
      other.ours == ours &&
      other.reason == reason &&
      other.controllable == controllable;

  @override
  int get hashCode => Object.hash(kind, baseUrl, name, state, ours, reason, controllable);
}

/// The bundled server's `/v1/local/models` routes.
final class ModelStatesApi {
  const ModelStatesApi(this._client);

  final ApiClient _client;

  /// Every model it tracks, after asking [servers] what they have loaded.
  Future<List<ModelLoadState>> list(List<LocalServer> servers) async {
    final query = [
      for (final s in servers)
        if (s.running) 'server=${Uri.encodeQueryComponent('${s.kind.name}|${s.baseUrl}')}',
    ].join('&');
    final json = await _client.getJson(
      query.isEmpty ? 'v1/local/models' : 'v1/local/models?$query',
      timeout: const Duration(seconds: 8),
    );
    return [
      for (final m in json['models'] as List<Object?>? ?? const [])
        if (m is Map<String, Object?>) ModelLoadState.fromJson(m),
    ];
  }

  /// Loads [name] on [server] (a large model takes a while).
  Future<ModelLoadState?> load(LocalServer server, String name) =>
      _act('load', server, name, const Duration(minutes: 3));

  Future<ModelLoadState?> unload(LocalServer server, String name) =>
      _act('unload', server, name, const Duration(seconds: 20));

  Future<ModelLoadState?> _act(String verb, LocalServer server, String name, Duration timeout) async {
    final json = await _client.postJson(
      'v1/local/models/$verb',
      {'kind': server.kind.name, 'base_url': server.baseUrl, 'name': name},
      headers: {if (server.apiKey case final k? when k.isNotEmpty) 'X-Local-Api-Key': k},
      timeout: timeout,
    );
    final m = json['model'];
    return m is Map<String, Object?> ? ModelLoadState.fromJson(m) : null;
  }

  /// Unloads every model EveryAI loaded (quit).
  Future<void> unloadOurs({Duration timeout = const Duration(seconds: 4)}) =>
      _client.postJson('v1/local/models/unload_ours', const {}, timeout: timeout);
}
