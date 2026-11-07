// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/preferences.dart';
import '../code/gateway_key.dart' show secretStoreProvider;
import 'data/local_http.dart';
import 'data/local_system.dart';
import 'data/ollama_pull.dart';
import 'data/server_probe.dart';
import 'domain/fm.dart';
import 'domain/hardware.dart';
import 'domain/local_server.dart';
import 'domain/packs.dart';

export 'data/ollama_pull.dart' show DownloadPhase, DownloadState;
export 'domain/fm.dart' show FmState, FmStatus, fmLicenceCommand;
export 'domain/hardware.dart' show HardwareSpec, HostOs, Gpu;
export 'domain/local_server.dart' show LocalModel, LocalServer, LocalServerKind, ManualServer;
export 'domain/packs.dart' show Catalogue, Pack, PackFit, PackModel, PackRole;

/// HTTP to local servers; tests override it.
final localHttpProvider = Provider<LocalHttp>((ref) => const RealLocalHttp());

/// This computer (hardware, Ollama and `fm` programs, servers we start); tests override it. Servers the app started
/// end with the container.
final localSystemProvider = Provider<LocalSystem>((ref) {
  final system = createLocalSystem();
  ref.onDispose(() => unawaited(system.stopStarted()));
  return system;
});

/// Where Ollama's own API is when it runs here by default.
final defaultOllamaRoot = Uri.parse('http://127.0.0.1:11434');

// ------------------------------------------------------------------ hardware

/// This computer's memory, GPUs and free disk, read once per run (Refresh re-reads it).
final hardwareSpecProvider = FutureProvider<HardwareSpec>((ref) => ref.watch(localSystemProvider).hardware());

// ------------------------------------------------------------------ manual servers

/// Servers the user added by URL, kept in prefs `models.local_servers`; keys in the keychain.
final manualServersProvider = NotifierProvider<ManualServers, List<ManualServer>>(ManualServers.new);

final class ManualServers extends Notifier<List<ManualServer>> {
  static const prefsKey = 'models.local_servers';

  Preferences get _prefs => ref.read(preferencesProvider);

  @override
  List<ManualServer> build() {
    final raw = ref.watch(preferencesProvider)[prefsKey];
    if (raw == null) return const [];
    try {
      final d = jsonDecode(raw);
      if (d is! List) return const [];
      return [
        for (final e in d)
          if (e is Map<String, Object?> && e['id'] is String && e['base_url'] is String) ManualServer.fromJson(e),
      ];
    } on FormatException {
      return const [];
    }
  }

  /// Adds a server at [baseUrl] (normalised to its `/v1` root); [apiKey] goes to the keychain. Returns it, or null
  /// when the URL isn't http(s).
  Future<ManualServer?> add({required String baseUrl, String label = '', String? apiKey}) async {
    final url = normaliseBaseUrl(baseUrl);
    if (url == null) return null;
    var n = 1;
    while (state.any((s) => s.id == 'custom:$n')) {
      n++;
    }
    final key = apiKey?.trim() ?? '';
    final server = ManualServer(
      id: 'custom:$n',
      label: label.trim().isEmpty ? Uri.parse(url).authority : label.trim(),
      baseUrl: url,
      hasKey: key.isNotEmpty,
    );
    if (key.isNotEmpty) await ref.read(secretStoreProvider).write(server.keyStoreName, key);
    _save([...state, server]);
    return server;
  }

  Future<void> remove(String id) async {
    final server = state.where((s) => s.id == id).firstOrNull;
    if (server == null) return;
    if (server.hasKey) await ref.read(secretStoreProvider).delete(server.keyStoreName);
    _save([
      for (final s in state)
        if (s.id != id) s,
    ]);
  }

  void _save(List<ManualServer> list) {
    _prefs[prefsKey] = list.isEmpty ? null : jsonEncode([for (final s in list) s.toJson()]);
    state = list;
  }
}

// ------------------------------------------------------------------ servers

/// Apple's on-device model: installed, terms agreed, supported here.
final fmStatusProvider = FutureProvider<FmStatus>((ref) => ref.watch(localSystemProvider).fmStatus());

/// Where `ollama` is installed (null: it isn't).
final ollamaPathProvider = FutureProvider<String?>((ref) => ref.watch(localSystemProvider).ollamaPath());

/// Every local server: the ones answering on their usual ports, Apple's `fm` (started by us when it's ready),
/// Ollama when installed but not running (`running: false`, with Start), and the user's own. A rescan is
/// `ref.invalidate(localServersProvider)` or [LocalServers.refresh].
final localServersProvider = AsyncNotifierProvider<LocalServers, List<LocalServer>>(LocalServers.new);

final class LocalServers extends AsyncNotifier<List<LocalServer>> {
  /// The port of the `fm serve` we started, kept across rescans so it starts once per run.
  static int? _fmPort;

  LocalHttp get _http => ref.read(localHttpProvider);
  LocalSystem get _system => ref.read(localSystemProvider);

  @override
  Future<List<LocalServer>> build() async {
    final manual = ref.watch(manualServersProvider);
    final found = await scanLocalPorts(_http);
    final out = [
      for (final s in found)
        if (s.kind != LocalServerKind.fm) s,
    ];
    final fm = await ref.watch(fmStatusProvider.future);
    if (fm.state == FmState.ready) {
      final port = await _ensureFm();
      out.insert(
        0,
        LocalServer(
          id: 'fm',
          kind: LocalServerKind.fm,
          label: LocalServerKind.fm.label,
          baseUrl: 'http://127.0.0.1:${port ?? 0}/v1',
          running: port != null,
          problem: port == null ? "Apple's model server didn't start" : null,
        ),
      );
    }
    if (!out.any((s) => s.kind == LocalServerKind.ollama) && await ref.watch(ollamaPathProvider.future) != null) {
      out.add(
        LocalServer(
          id: 'ollama',
          kind: LocalServerKind.ollama,
          label: LocalServerKind.ollama.label,
          baseUrl: '$defaultOllamaRoot/v1',
          running: false,
          problem: 'Installed, not running',
        ),
      );
    }
    final store = ref.read(secretStoreProvider);
    for (final m in manual) {
      final key = m.hasKey ? await store.read(m.keyStoreName) : null;
      final server = LocalServer(
        id: m.id,
        kind: LocalServerKind.custom,
        label: m.label,
        baseUrl: m.baseUrl,
        apiKey: key,
        manual: true,
      );
      final answer = await _http.get(
        Uri.parse('${m.baseUrl}/models'),
        headers: {if (key != null && key.isNotEmpty) 'Authorization': 'Bearer $key'},
      );
      out.add(answer != null && answer.ok ? server : server.copyWith(running: false, problem: "Didn't answer"));
    }
    return out;
  }

  Future<int?> _ensureFm() async {
    if (_fmPort case final p?) {
      if ((await _http.get(Uri.parse('http://127.0.0.1:$p/health')))?.ok ?? false) return p;
    }
    final port = await _system.startFm();
    if (port == null) return null;
    for (var i = 0; i < 40; i++) {
      if ((await _http.get(Uri.parse('http://127.0.0.1:$port/health')))?.ok ?? false) return _fmPort = port;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return null;
  }

  /// Scans again (after an install, a licence agreement or a server started by hand).
  Future<void> refresh() async {
    ref.invalidate(fmStatusProvider);
    ref.invalidate(ollamaPathProvider);
    ref.invalidateSelf();
    await future;
  }

  /// Starts Ollama when it's installed but not running, then rescans once it answers.
  Future<bool> startOllama() async {
    final path = await ref.read(ollamaPathProvider.future);
    if (path == null || !await _system.startOllama(path)) return false;
    for (var i = 0; i < 40; i++) {
      if ((await _http.get(defaultOllamaRoot.replace(path: '/api/version')))?.ok ?? false) break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    await refresh();
    return true;
  }

  /// Forgets the `fm serve` port (tests).
  static void resetForTest() => _fmPort = null;
}

/// The server with [id] among the running ones.
LocalServer? localServerById(List<LocalServer> servers, String id) => servers.where((s) => s.id == id).firstOrNull;

// ------------------------------------------------------------------ models

/// Every model the running local servers serve, Apple's first, then by server.
final localModelsProvider = FutureProvider<List<LocalModel>>((ref) async {
  final servers = await ref.watch(localServersProvider.future);
  final http = ref.watch(localHttpProvider);
  final lists = await Future.wait([
    for (final s in servers)
      if (s.running) listServerModels(http, s),
  ]);
  return [for (final l in lists) ...l];
});

/// The model side jobs run on (titles, follow-ups, decide): Apple's on-device model on macOS, else the smallest
/// local model with a known size, else the first one. Null when there's none.
final smallestLocalModelProvider = Provider<LocalModel?>((ref) {
  final models = ref.watch(localModelsProvider).value ?? const <LocalModel>[];
  if (models.isEmpty) return null;
  final fm = models.where((m) => m.serverId == 'fm' && m.name == 'system').firstOrNull;
  if (fm != null) return fm;
  final sized = models.where((m) => m.sizeBytes != null).toList()..sort((a, b) => a.sizeBytes!.compareTo(b.sizeBytes!));
  return sized.firstOrNull ?? models.first;
});

/// The server a local model is on (for the `X-Local-Base-Url` / `X-Local-Api-Key` headers), null when it's gone.
final localServerOfProvider = Provider.family<LocalServer?, String>((ref, modelId) {
  final models = ref.watch(localModelsProvider).value ?? const <LocalModel>[];
  final servers = ref.watch(localServersProvider).value ?? const <LocalServer>[];
  final model = models.where((m) => m.id == modelId).firstOrNull;
  return model == null ? null : localServerById(servers, model.serverId);
});

// ------------------------------------------------------------------ catalogue and packs

/// Where the newest catalogue lives (the repo's main branch).
final catalogueUrl = Uri.parse(
  'https://raw.githubusercontent.com/xuckless/everyai-mono/main/frontend/assets/local_models.json',
);

/// The starter packs: the newest of the bundled file, the last fetched copy (prefs `models.local_catalogue`) and a
/// fresh fetch. A copy that doesn't parse is never used.
final catalogueProvider = FutureProvider<Catalogue>((ref) async {
  const cacheKey = 'models.local_catalogue';
  final prefs = ref.watch(preferencesProvider);
  var best = parseCatalogue(await ref.watch(bundledCatalogueProvider.future));
  final cached = prefs[cacheKey] == null ? null : parseCatalogue(prefs[cacheKey]!);
  if (cached != null && (best == null || cached.version > best.version)) best = cached;
  final fresh = await ref.watch(localHttpProvider).get(catalogueUrl, timeout: const Duration(seconds: 6));
  final fetched = fresh != null && fresh.ok ? parseCatalogue(fresh.body) : null;
  if (fetched != null && (best == null || fetched.version >= best.version)) {
    prefs[cacheKey] = fresh!.body;
    best = fetched;
  }
  return best ?? const Catalogue(version: 0, packs: []);
});

/// The catalogue shipped in the app.
final bundledCatalogueProvider = FutureProvider<String>((ref) => rootBundle.loadString('assets/local_models.json'));

/// Each pack against this computer's hardware.
final packsProvider = FutureProvider<List<PackFit>>((ref) async {
  final catalogue = await ref.watch(catalogueProvider.future);
  final spec = await ref.watch(hardwareSpecProvider.future);
  return fitPacks(catalogue.packs, spec);
});

// ------------------------------------------------------------------ downloads

/// Model downloads through Ollama, one at a time in the background, by tag.
final downloadsProvider = NotifierProvider<Downloads, Map<String, DownloadState>>(Downloads.new);

final class Downloads extends Notifier<Map<String, DownloadState>> {
  final _queue = <String>[];
  StreamSubscription<DownloadState>? _current;
  String? _running;

  @override
  Map<String, DownloadState> build() {
    ref.onDispose(() => _current?.cancel());
    return const {};
  }

  Uri get _root {
    final servers = ref.read(localServersProvider).value ?? const <LocalServer>[];
    final ollama = servers.where((s) => s.kind == LocalServerKind.ollama && s.running).firstOrNull;
    if (ollama == null) return defaultOllamaRoot;
    final base = Uri.parse(ollama.baseUrl);
    return base.replace(path: '');
  }

  /// Queues [tags] (ones already queued, running or done are skipped).
  void enqueue(Iterable<String> tags) {
    final next = {...state};
    for (final t in tags) {
      final s = next[t];
      if (s != null && (s.active || s.phase == DownloadPhase.done)) continue;
      next[t] = DownloadState(tag: t);
      _queue.add(t);
    }
    state = next;
    _pump();
  }

  /// Stops [tag]: queued ones leave the queue; the running one stops (Ollama keeps what it has, so Download again
  /// resumes it).
  void cancel(String tag) {
    _queue.remove(tag);
    if (_running == tag) {
      // Not awaited: the request ends with the subscription, and nothing here needs to wait for it.
      unawaited(_current?.cancel());
      _current = null;
      _running = null;
    }
    final s = state[tag];
    if (s != null && s.active) state = {...state, tag: s.copyWith(phase: DownloadPhase.cancelled)};
    _pump();
  }

  /// Deletes an installed model from Ollama. Null when it worked, else why not.
  Future<String?> delete(String tag) async {
    final problem = await deleteModel(ref.read(localHttpProvider), _root, tag);
    if (problem == null) {
      state = {...state}..remove(tag);
      ref.invalidate(localModelsProvider);
    }
    return problem;
  }

  void _pump() {
    if (_running != null || _queue.isEmpty) return;
    final tag = _queue.removeAt(0);
    _running = tag;
    _current = pullModel(ref.read(localHttpProvider), _root, tag).listen(
      (s) => state = {...state, tag: s},
      onDone: () {
        if (_running != tag) return;
        _running = null;
        _current = null;
        if (state[tag]?.phase == DownloadPhase.done) ref.invalidate(localModelsProvider);
        _pump();
      },
    );
  }
}
