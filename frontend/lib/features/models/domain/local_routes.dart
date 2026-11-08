// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/foundation.dart';

/// Where a local model (`local/<name>`) is served: an OpenAI-compatible
/// root (`http://127.0.0.1:11434/v1`), its key if it has one, and what the
/// model can do. Filled from the local servers found (features/local_models).
@immutable
final class LocalRoute {
  const LocalRoute({
    required this.baseUrl,
    required this.name,
    this.apiKey,
    this.kind = '',
    this.contextTokens = 0,
    this.tools = false,
    this.vision = false,
    this.reasoning = false,
  });

  final String baseUrl;

  /// The model's name on its server (the id without `local/`).
  final String name;
  final String? apiKey;

  /// The server's kind (`ollama`, `lmstudio`, `fm`, …): how the bundled server loads, unloads and talks to it.
  final String kind;
  final int contextTokens;
  final bool tools;
  final bool vision;
  final bool reasoning;

  static const prefix = 'local/';

  static bool isLocal(String modelId) => modelId.startsWith(prefix);

  /// The bundled server's headers for a turn on this model (the contract in
  /// backend-exp/README.md "Local mode").
  Map<String, String> get headers => {
    'X-Local-Base-Url': baseUrl,
    'X-Local-Api-Key': ?apiKey,
    if (kind.isNotEmpty) 'X-Local-Kind': kind,
    'X-Local-Caps': [if (tools) 'tools', if (vision) 'vision', if (reasoning) 'reasoning'].join(','),
    if (contextTokens > 0) 'X-Local-Context': '$contextTokens',
  };

  /// The same, for side jobs (titles, follow-ups, decide) run on this model.
  Map<String, String> get auxHeaders => {
    'X-Local-Aux-Model': '$prefix$name',
    'X-Local-Aux-Base-Url': baseUrl,
    'X-Local-Aux-Api-Key': ?apiKey,
    if (kind.isNotEmpty) 'X-Local-Aux-Kind': kind,
  };
}

/// The routes of every local model found, by id; a snapshot the model
/// clients read per call (like `ModelBilling.current`), so a server that
/// moved ports is followed without restarting a session.
final class LocalRoutes {
  LocalRoutes._();

  static Map<String, LocalRoute> current = const {};

  /// The model side jobs run on when no key covers them (FM on macOS, else
  /// the smallest local model), or null.
  static LocalRoute? aux;

  static LocalRoute? of(String modelId) => current[modelId];

  /// Called before the Code harness calls a local model (it goes to the model's server directly): the app tells
  /// the bundled server, which tracks what EveryAI loaded. Set by the app; null in tests.
  static void Function(LocalRoute route)? onUse;
}
