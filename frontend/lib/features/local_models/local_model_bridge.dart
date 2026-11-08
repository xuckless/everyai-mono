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
import 'data/model_states.dart';
import 'local_models_providers.dart';

export 'data/model_states.dart' show ModelLoad, ModelLoadState;

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
        kind: server.kind.name,
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
  if (m.serverId == 'fm') return 'Apple Intelligence';
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

/// Ends what the app started for local models when it quits, in order: the
/// bundled server unloads every model EveryAI loaded (on any server, the
/// user's too) and exits; then the model servers EveryAI started stop (ones
/// the user runs are left running). One shutdown, joined by every caller; 8 s
/// at most. The shell listens to it from app start.
final localShutdownProvider = Provider<void>((ref) {
  Future<void>? shutdown;
  Future<void> stopAll() => shutdown ??= () async {
    await ref.read(localBackendProvider).close();
    await ref.read(serverLifecyclesProvider.notifier).stopOwned();
  }().timeout(const Duration(seconds: 8), onTimeout: () {});
  final lifecycle = AppLifecycleListener(
    onExitRequested: () async {
      await stopAll();
      return AppExitResponse.exit;
    },
    onDetach: () => unawaited(stopAll()),
  );
  ref.onDispose(lifecycle.dispose);
});

/// Each local model's load state, as the bundled server tracks it (by
/// [ModelLoadState.key]), with Load / Unload. Refreshed with the servers, and
/// every second while one is loading or unloading.
final localModelStatesProvider = AsyncNotifierProvider<LocalModelStates, Map<String, ModelLoadState>>(
  LocalModelStates.new,
);

final class LocalModelStates extends AsyncNotifier<Map<String, ModelLoadState>> {
  Timer? _poll;
  final _actions = <String, Future<String?>>{};

  @override
  Future<Map<String, ModelLoadState>> build() async {
    ref.onDispose(() => _poll?.cancel());
    if (!ref.watch(localDetectionProvider)) return const {};
    final servers = ref.watch(localServersProvider).value ?? const <LocalServer>[];
    final api = await _api();
    if (api == null) return const {};
    final list = await api.list(servers).catchError((Object _) => const <ModelLoadState>[]);
    final out = {for (final m in list) m.key: m};
    _schedule(out);
    return out;
  }

  Future<ModelStatesApi?> _api() async {
    final client = await ref.read(localApiProvider).client();
    return client == null ? null : ModelStatesApi(client);
  }

  void _schedule(Map<String, ModelLoadState> states) {
    _poll?.cancel();
    if (states.values.any((m) => m.state.busy)) {
      _poll = Timer(const Duration(seconds: 1), () {
        if (ref.mounted) ref.invalidateSelf();
      });
    }
  }

  /// [model]'s state on [server], or null when the bundled server hasn't seen it (unloaded as far as it knows).
  ModelLoadState? of(LocalServer server, String model) => state.value?['${server.baseUrl}|$model'];

  /// Loads [model] on [server]: null when it worked, else why not. One action per model at a time.
  Future<String?> load(LocalServer server, String model) => _act(server, model, load: true);

  Future<String?> unload(LocalServer server, String model) => _act(server, model, load: false);

  Future<String?> _act(LocalServer server, String model, {required bool load}) {
    final key = '${server.baseUrl}|$model';
    return _actions[key] ??=
        () async {
          try {
            final api = await _api();
            if (api == null) return ref.read(localBackendProvider).problem ?? 'The built-in server is not running.';
            // Shown as loading/unloading at once; the server's answer replaces it.
            final busy = ModelLoadState(
              kind: server.kind.name,
              baseUrl: server.baseUrl,
              name: model,
              state: load ? ModelLoad.loading : ModelLoad.unloading,
              controllable: true,
            );
            state = AsyncData({...?state.value, key: busy});
            final after = await (load ? api.load(server, model) : api.unload(server, model));
            if (after != null && ref.mounted) state = AsyncData({...?state.value, key: after});
            return after?.state == ModelLoad.failed ? after?.reason ?? 'It failed.' : null;
          } on Object catch (e) {
            return '$e';
          } finally {
            if (ref.mounted) ref.invalidateSelf();
          }
        }().whenComplete(() {
          // A block body: returning the removed future would make whenComplete wait on itself.
          _actions.remove(key);
        });
  }
}

/// Tells the bundled server about local models the Code harness calls
/// directly, so what it loads is unloaded at quit too. Once per model and
/// server per run.
final localUseTrackerProvider = Provider<void>((ref) {
  if (!ref.watch(localDetectionProvider)) return;
  final told = <String>{};
  LocalRoutes.onUse = (route) {
    if (!told.add('${route.baseUrl}|${route.name}')) return;
    final servers = ref.read(localServersProvider).value ?? const <LocalServer>[];
    final server = servers.where((s) => s.baseUrl == route.baseUrl).firstOrNull;
    if (server == null) return;
    unawaited(ref.read(localModelStatesProvider.notifier).load(server, route.name));
  };
  ref.onDispose(() => LocalRoutes.onUse = null);
});

/// The local model new Code sessions default to when the user has no key: one
/// that calls tools, a coding model first ("coder", "coding" in its name),
/// else the one with the biggest window. Apple's model is never picked (its
/// window is too small for the harness). Null when there's none.
final localCodeModelProvider = Provider<ModelSpec?>((ref) {
  final tools = [
    for (final s in ref.watch(localModelSpecsProvider))
      if (s.tools && s.id != appleModelId) s,
  ];
  if (tools.isEmpty) return null;
  final coders = tools.where((s) => s.id.value.toLowerCase().contains('cod')).toList();
  final pool = coders.isEmpty ? tools : coders;
  return pool.reduce((a, b) => b.contextLength > a.contextLength ? b : a);
});

/// Whether the EveryAI harness has nothing to run on: no key of the user's
/// and no local model that calls tools (in the app on a desktop; never in
/// tests). Outside agents run on their own logins and don't need either.
final everyaiHasNoModelProvider = Provider<bool>((ref) {
  if (!ref.watch(localDetectionProvider)) return false;
  final keys = ref.watch(byokKeysProvider);
  return keys.hasValue && keys.value!.isEmpty && ref.watch(localCodeModelProvider) == null;
});
