// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/local_backend/local_backend_providers.dart';

import '../../core/platform/platform_kind.dart';
import '../models/domain/local_routes.dart';
import '../settings/byok_keys.dart' show byokKeysProvider;
import 'data/local_system.dart' show runningUnderTest;
import '../models/domain/model_catalog.dart';
import 'local_models_providers.dart';

/// Apple's on-device model, as the model list names it.
const appleModelId = ModelId('local/system');

/// Whether the app looks for local models at all: desktops only, and not in
/// tests (which override this to opt in).
final localDetectionProvider = Provider<bool>((ref) => Host.isDesktop && !runningUnderTest);

/// What the pickers and the bundled server need to know of each local model
/// found: its [LocalRoute] (where it's served, what it can do). Also keeps
/// [LocalRoutes.current] and [LocalRoutes.aux] in step, which the Code
/// harness reads per call.
final localRoutesProvider = Provider<Map<String, LocalRoute>>((ref) {
  if (!ref.watch(localDetectionProvider)) return const {};
  final models = ref.watch(localModelsProvider).value ?? const <LocalModel>[];
  final servers = ref.watch(localServersProvider).value ?? const <LocalServer>[];
  final routes = <String, LocalRoute>{};
  for (final m in models) {
    final server = servers.where((s) => s.id == m.serverId).firstOrNull;
    if (server == null || !server.running) continue;
    // The same name on two servers: the first one found keeps it.
    routes.putIfAbsent(
      m.id,
      () => LocalRoute(
        baseUrl: server.baseUrl,
        name: m.name,
        apiKey: server.apiKey,
        contextTokens: m.contextTokens ?? 0,
        tools: m.tools,
        vision: m.vision,
        reasoning: m.reasoning,
      ),
    );
  }
  LocalRoutes.current = Map.unmodifiable(routes);
  final small = ref.watch(smallestLocalModelProvider);
  LocalRoutes.aux = small == null ? null : routes[small.id];
  return routes;
});

/// The local models as [ModelSpec]s for the pickers ("On this computer").
final localModelSpecsProvider = Provider<List<ModelSpec>>((ref) {
  final routes = ref.watch(localRoutesProvider);
  if (routes.isEmpty) return const [];
  final models = ref.watch(localModelsProvider).value ?? const <LocalModel>[];
  final servers = ref.watch(localServersProvider).value ?? const <LocalServer>[];
  return [
    for (final m in models)
      if (routes[m.id] case final route?)
        ModelSpec(
          id: ModelId(m.id),
          provider: ModelProvider.of('local'),
          name: localModelName(m),
          blurb: 'On this computer · ${servers.where((s) => s.id == m.serverId).firstOrNull?.label ?? m.serverId}',
          imageInput: route.vision,
          inputs: {'text', if (route.vision) 'image'},
          contextLength: route.contextTokens,
          free: true,
          tools: route.tools,
          reasoning: route.reasoning,
        ),
  ];
});

/// "Apple Intelligence", "qwen3.5 9b": the server's name, made readable.
String localModelName(LocalModel m) {
  if (m.serverId == 'fm') return m.name == 'pcc' ? 'Apple Private Cloud' : 'Apple Intelligence';
  return m.name.replaceAll(':latest', '').replaceAll(':', ' ');
}

/// The headers of a chat turn (or a side job of one) on [modelId]: the
/// user's key headers ([keyHeaders]), plus for a turn on the bundled server
/// where the local model is served, and the local model side jobs run on
/// when no OpenRouter key covers them. A credit turn gets [keyHeaders] only
/// (empty), so it stays on our server.
Map<String, String> chatTurnHeaders(String modelId, Map<String, String> keyHeaders) {
  final route = LocalRoutes.of(modelId);
  if (route == null && keyHeaders.isEmpty) return keyHeaders;
  return {
    ...keyHeaders,
    ...?route?.headers,
    if (!keyHeaders.containsKey('X-Provider-Key-OpenRouter')) ...?LocalRoutes.aux?.auxHeaders,
  };
}

/// Whether Chat has nothing to run on: no key of the user's and no local
/// model. The chat home then shows "Chat needs a model" instead of a
/// composer that can't send. Waits for the keys to load (false meanwhile).
final chatNeedsModelProvider = Provider<bool>((ref) {
  final keys = ref.watch(byokKeysProvider);
  if (!keys.hasValue) return false;
  return keys.value!.isEmpty && ref.watch(localModelSpecsProvider).isEmpty;
});

/// Ends what the app started for local models when it quits: the model
/// servers (`ollama serve`, `fm serve`; ones the user runs are left alone)
/// and the bundled EveryAI server. The shell listens to it from app start.
final localShutdownProvider = Provider<void>((ref) {
  Future<void> stopAll() =>
      Future.wait([ref.read(localSystemProvider).stopStarted(), ref.read(localBackendProvider).stop()])
          .timeout(const Duration(seconds: 3), onTimeout: () => const []);
  final lifecycle = AppLifecycleListener(
    onExitRequested: () async {
      await stopAll();
      return AppExitResponse.exit;
    },
    onDetach: () => unawaited(stopAll()),
  );
  ref.onDispose(lifecycle.dispose);
});
