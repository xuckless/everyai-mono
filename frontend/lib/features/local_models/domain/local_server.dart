// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/foundation.dart';

/// The kinds of model server that run on the user's own computer (or one they added by URL).
enum LocalServerKind {
  ollama('Ollama'),
  fm('Apple Intelligence'),
  lmstudio('LM Studio'),
  llamacpp('llama.cpp'),
  jan('Jan'),
  vllm('vLLM'),
  mlx('MLX'),
  custom('Server');

  const LocalServerKind(this.label);
  final String label;

  static LocalServerKind? parse(Object? v) => values.where((k) => k.name == v).firstOrNull;
}

/// A model server: [baseUrl] is its OpenAI-compatible root (ending in `/v1`), the URL the bundled backend and the
/// EveryAI harness call. [running] is false for a server that's installed but not started (Ollama), or that didn't
/// answer (a manual one).
@immutable
final class LocalServer {
  const LocalServer({
    required this.id,
    required this.kind,
    required this.label,
    required this.baseUrl,
    this.apiKey,
    this.running = true,
    this.manual = false,
    this.problem,
    this.startCommand,
  });

  /// `ollama`, `fm`, `lmstudio`, ... for a found one (one per kind); `custom:<n>` for a manual one.
  final String id;
  final LocalServerKind kind;
  final String label;
  final String baseUrl;
  final String? apiKey;
  final bool running;

  /// Added by the user (kept in prefs), not found by a scan.
  final bool manual;

  /// Why it can't be used now, in plain words; null when it can.
  final String? problem;

  /// A manual server's own start command (run through the shell), when the user gave one.
  final String? startCommand;

  LocalServer copyWith({bool? running, String? problem, String? apiKey, bool clearProblem = false}) => LocalServer(
    id: id,
    kind: kind,
    label: label,
    baseUrl: baseUrl,
    apiKey: apiKey ?? this.apiKey,
    running: running ?? this.running,
    manual: manual,
    problem: clearProblem ? null : problem ?? this.problem,
    startCommand: startCommand,
  );

  @override
  bool operator ==(Object other) =>
      other is LocalServer &&
      other.id == id &&
      other.kind == kind &&
      other.label == label &&
      other.baseUrl == baseUrl &&
      other.apiKey == apiKey &&
      other.running == running &&
      other.manual == manual &&
      other.problem == problem &&
      other.startCommand == startCommand;

  @override
  int get hashCode => Object.hash(id, kind, label, baseUrl, apiKey, running, manual, problem, startCommand);
}

/// A model one local server serves. [id] is `local/<name>`, the id the app and the bundled backend use; [name] is
/// the server's own (what goes in the request's `model` field).
@immutable
final class LocalModel {
  const LocalModel({
    required this.name,
    required this.serverId,
    this.contextTokens,
    this.contextGuessed = false,
    this.tools = false,
    this.vision = false,
    this.reasoning = false,
    this.sizeBytes,
  });

  final String name;
  final String serverId;

  /// The context window in tokens, when the server says (or [contextGuessed]).
  final int? contextTokens;

  /// [contextTokens] is our assumption, not the server's answer.
  final bool contextGuessed;
  final bool tools;
  final bool vision;
  final bool reasoning;

  /// On-disk size, when the server says.
  final int? sizeBytes;

  static const idPrefix = 'local/';

  String get id => '$idPrefix$name';

  /// The `X-Local-Caps` value for the bundled backend.
  String get capsHeader => [if (tools) 'tools', if (vision) 'vision', if (reasoning) 'reasoning'].join(',');

  static bool isLocalId(String id) => id.startsWith(idPrefix);

  @override
  bool operator ==(Object other) =>
      other is LocalModel &&
      other.name == name &&
      other.serverId == serverId &&
      other.contextTokens == contextTokens &&
      other.contextGuessed == contextGuessed &&
      other.tools == tools &&
      other.vision == vision &&
      other.reasoning == reasoning &&
      other.sizeBytes == sizeBytes;

  @override
  int get hashCode => Object.hash(name, serverId, contextTokens, contextGuessed, tools, vision, reasoning, sizeBytes);

  @override
  String toString() => 'LocalModel($id @ $serverId)';
}

/// A server the user added by URL, as kept in prefs `models.local_servers` (its key, if any, lives in the keychain
/// under [keyStoreName]).
@immutable
final class ManualServer {
  const ManualServer({
    required this.id,
    required this.label,
    required this.baseUrl,
    this.hasKey = false,
    this.startCommand,
  });

  final String id;
  final String label;
  final String baseUrl;
  final bool hasKey;

  /// How EveryAI starts it (a shell command line), when the user gave one; else it only stops it.
  final String? startCommand;

  String get keyStoreName => 'local_server.$id';

  factory ManualServer.fromJson(Map<String, Object?> j) => ManualServer(
    id: j['id']! as String,
    label: j['label'] as String? ?? '',
    baseUrl: j['base_url']! as String,
    hasKey: j['has_key'] == true,
    startCommand: j['start_command'] as String?,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'base_url': baseUrl,
    if (hasKey) 'has_key': true,
    if (startCommand case final c? when c.trim().isNotEmpty) 'start_command': c.trim(),
  };
}

/// [raw] as an OpenAI-compatible root: trimmed, no trailing slash, `/v1` added when the URL has no path. Null when it
/// isn't an http(s) URL.
String? normaliseBaseUrl(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return null;
  if (!s.contains('://')) s = 'http://$s';
  final uri = Uri.tryParse(s);
  if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https') || uri.host.isEmpty) return null;
  var path = uri.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  if (path.isEmpty) path = '/v1';
  return uri.replace(path: path, query: null, fragment: null).toString().replaceAll(RegExp(r'\?$'), '');
}
