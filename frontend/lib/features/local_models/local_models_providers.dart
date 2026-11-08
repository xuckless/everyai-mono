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
import 'domain/server_lifecycle.dart';
import 'local_model_bridge.dart' show localDetectionProvider;

export 'data/ollama_pull.dart' show DownloadPhase, DownloadState;
export 'domain/fm.dart' show FmState, FmStatus, fmLicenceCommand;
export 'domain/hardware.dart' show HardwareSpec, HostOs, Gpu;
export 'domain/local_server.dart' show LocalModel, LocalServer, LocalServerKind, ManualServer;
export 'domain/packs.dart' show Catalogue, Pack, PackFit, PackModel, PackRole;
export 'domain/server_lifecycle.dart';

/// HTTP to local servers; tests override it.
final localHttpProvider = Provider<LocalHttp>((ref) => const RealLocalHttp());

/// This computer (hardware, Ollama and `fm` programs, servers we start); tests override it. Servers the app started
/// end with the container.
final localSystemProvider = Provider<LocalSystem>((ref) {
  final system = createLocalSystem();
  ref.onDispose(() => unawaited(system.stopAllOwned()));
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
  Future<ManualServer?> add({required String baseUrl, String label = '', String? apiKey, String? startCommand}) async {
    final url = normaliseBaseUrl(baseUrl);
    if (url == null) return null;
    var n = 1;
    while (state.any((s) => s.id == 'custom:$n') || _reserved.contains('custom:$n')) {
      n++;
    }
    // Held through the keychain write, so an add that starts meanwhile picks the next id.
    _reserved.add('custom:$n');
    final key = apiKey?.trim() ?? '';
    final server = ManualServer(
      id: 'custom:$n',
      label: label.trim().isEmpty ? Uri.parse(url).authority : label.trim(),
      baseUrl: url,
      hasKey: key.isNotEmpty,
      startCommand: startCommand?.trim().isEmpty ?? true ? null : startCommand!.trim(),
    );
    try {
      if (key.isNotEmpty) await ref.read(secretStoreProvider).write(server.keyStoreName, key);
      _save([...state, server]);
    } finally {
      _reserved.remove(server.id);
    }
    return server;
  }

  /// Ids an [add] still under way has taken.
  final _reserved = <String>{};

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

/// Where LM Studio's `lms` is (null: it isn't installed).
final lmsPathProvider = FutureProvider<String?>((ref) => ref.watch(localSystemProvider).lmsPath());

/// The port of the `fm serve` EveryAI started this run, null while there's none.
final fmPortProvider = NotifierProvider<FmPort, int?>(FmPort.new);

final class FmPort extends Notifier<int?> {
  @override
  int? build() => null;
  void set(int? port) => state = port;
}

/// Every local server: the ones answering on their usual ports, Apple's `fm serve` (on the port EveryAI started it
/// on), Ollama and LM Studio when installed but not running (`running: false`), and the user's own. A scan only
/// looks: starting and stopping are [serverLifecyclesProvider]'s. A rescan is [LocalServers.refresh].
final localServersProvider = AsyncNotifierProvider<LocalServers, List<LocalServer>>(LocalServers.new);

final class LocalServers extends AsyncNotifier<List<LocalServer>> {
  LocalHttp get _http => ref.read(localHttpProvider);

  @override
  Future<List<LocalServer>> build() async {
    final manual = ref.watch(manualServersProvider);
    final fmPort = ref.watch(fmPortProvider);
    final found = await scanLocalPorts(_http);
    final out = [
      for (final s in found)
        if (s.kind != LocalServerKind.fm) s,
    ];
    final fm = await ref.watch(fmStatusProvider.future);
    if (fm.state == FmState.ready) {
      final up = fmPort != null && ((await _http.get(Uri.parse('http://127.0.0.1:$fmPort/health')))?.ok ?? false);
      out.insert(
        0,
        LocalServer(
          id: 'fm',
          kind: LocalServerKind.fm,
          label: LocalServerKind.fm.label,
          baseUrl: 'http://127.0.0.1:${fmPort ?? 0}/v1',
          running: up,
          problem: up ? null : 'Not running',
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
    if (!out.any((s) => s.kind == LocalServerKind.lmstudio) && await ref.watch(lmsPathProvider.future) != null) {
      out.add(
        const LocalServer(
          id: 'lmstudio',
          kind: LocalServerKind.lmstudio,
          label: 'LM Studio',
          baseUrl: 'http://127.0.0.1:1234/v1',
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
        startCommand: m.startCommand,
      );
      final answer = await _http.get(
        Uri.parse('${m.baseUrl}/models'),
        headers: {if (key != null && key.isNotEmpty) 'Authorization': 'Bearer $key'},
      );
      out.add(answer != null && answer.ok ? server : server.copyWith(running: false, problem: "Didn't answer"));
    }
    return out;
  }

  /// Scans again (after an install, a licence agreement, a start or a stop).
  Future<void> refresh() async {
    ref.invalidate(fmStatusProvider);
    ref.invalidate(ollamaPathProvider);
    ref.invalidate(lmsPathProvider);
    ref.invalidateSelf();
    await future;
  }
}

/// Each server's phase ([ServerPhase], one state machine per server id; see [nextPhase]), and the Start / Stop
/// actions. Scans feed it `seenUp` / `seenDown`; an action runs one at a time per server and ends in its own event.
final serverLifecyclesProvider = NotifierProvider<ServerLifecycles, Map<String, ServerPhase>>(ServerLifecycles.new);

final class ServerLifecycles extends Notifier<Map<String, ServerPhase>> {
  /// Apple's server starts by itself (it's the default chat model) unless the user stopped it (prefs).
  static const fmAutostartKey = 'models.fm.autostart';

  LocalSystem get _system => ref.read(localSystemProvider);
  LocalHttp get _http => ref.read(localHttpProvider);

  final _actions = <String, Future<String?>>{};

  /// LM Studio's server isn't our child process: whether EveryAI started it with `lms server start`.
  var _lmsOurs = false;

  /// Apple's server was started (or tried) by itself once this run.
  var _fmTried = false;

  @override
  Map<String, ServerPhase> build() {
    // Desktops only, and tests that opt in: nothing here probes this computer otherwise.
    if (!ref.watch(localDetectionProvider)) return const {};
    ref.listen(localServersProvider, (_, next) {
      // A rescan in flight still carries the old list: only a finished scan counts.
      if (next case AsyncData(:final value)) _observe(value);
    });
    // A scan that finished before this existed: seen right after build (state can't change inside it).
    if (ref.read(localServersProvider).value case final servers?) {
      Future.microtask(() {
        if (ref.mounted) _observe(servers);
      });
    }
    return const {};
  }

  /// The phase of [server]: its machine's, else what the scan says.
  ServerPhase phaseOf(LocalServer server) =>
      state[server.id] ?? (server.running ? ServerRunning(_ownerOf(server.id)) : const ServerStopped());

  ServerOwner _ownerOf(String id) =>
      _system.owns(id) || (id == 'lmstudio' && _lmsOurs) ? ServerOwner.everyai : ServerOwner.outside;

  void _observe(List<LocalServer> servers) {
    for (final s in servers) {
      _apply(s.id, s.running ? SeenUp(_ownerOf(s.id)) : const SeenDown());
    }
    // A server the scan no longer finds at all (one started elsewhere, now gone).
    for (final id in state.keys.toList()) {
      if (!servers.any((s) => s.id == id)) _apply(id, const SeenDown());
    }
    final fm = servers.where((s) => s.id == 'fm').firstOrNull;
    if (fm != null && !fm.running && !_fmTried && ref.read(preferencesProvider)[fmAutostartKey] != '0') {
      _fmTried = true;
      unawaited(start(fm));
    }
  }

  bool _apply(String id, ServerEvent e) {
    final from = state[id] ?? const ServerStopped();
    final to = nextPhase(from, e);
    if (to == null) return false;
    if (to != from || !state.containsKey(id)) state = {...state, id: to};
    return true;
  }

  /// Starts [server]: null when it runs, else why not. A start already running for it is joined.
  Future<String?> start(LocalServer server) =>
      // A block body: `=> _actions.remove(...)` would return this very future, and whenComplete would wait on itself.
      _actions[server.id] ??= _start(server).whenComplete(() {
        _actions.remove(server.id);
      });

  /// Stops [server] (whoever started it): null when it stopped, else why not.
  Future<String?> stop(LocalServer server) {
    final running = _actions[server.id];
    // A stop asked while a start runs: the start's own outcome is dropped (Starting → Stopping).
    if (running != null && state[server.id] is! ServerStarting) return running;
    late final Future<String?> f;
    f = _stop(server).whenComplete(() {
      if (identical(_actions[server.id], f)) _actions.remove(server.id);
    });
    return _actions[server.id] = f;
  }

  /// Whether EveryAI can start [server] at all.
  static bool canStart(LocalServer s) =>
      s.kind == LocalServerKind.ollama ||
      s.kind == LocalServerKind.fm ||
      s.kind == LocalServerKind.lmstudio ||
      (s.manual && (s.startCommand ?? '').trim().isNotEmpty);

  Future<String?> _start(LocalServer server) async {
    if (!_apply(server.id, const StartAsked())) return 'It is busy.';
    final reason = await _launch(server);
    if (reason != null) {
      _apply(server.id, StartFailed(reason));
      return reason;
    }
    await ref.read(localServersProvider.notifier).refresh();
    return null;
  }

  /// Launches [server] and waits until it answers; null when it does.
  Future<String?> _launch(LocalServer server) async {
    final logDir = await ref.read(localSystemProvider).logDir();
    LaunchedServer? launched;
    switch (server.kind) {
      case LocalServerKind.ollama:
        final path = await ref.read(ollamaPathProvider.future);
        if (path == null) return "Ollama isn't installed.";
        final port = Uri.parse(server.baseUrl).port;
        launched = await _system.launch(
          server.id,
          path,
          const ['serve'],
          env: {'OLLAMA_HOST': '127.0.0.1:$port'},
          logPath: logDir == null ? null : '$logDir/ollama.log',
        );
      case LocalServerKind.fm:
        final port = await _system.freePort();
        if (port == null) return 'No free port for it.';
        launched = await _system.launch(server.id, fmExecutable, [
          'serve',
          '--host',
          '127.0.0.1',
          '--port',
          '$port',
        ], logPath: logDir == null ? null : '$logDir/fm.log');
        if (launched != null) {
          ref.read(fmPortProvider.notifier).set(port);
          ref.read(preferencesProvider)[fmAutostartKey] = null;
        }
      case LocalServerKind.lmstudio:
        final lms = await ref.read(lmsPathProvider.future);
        if (lms == null) return "LM Studio's `lms` command isn't installed.";
        final port = Uri.parse(server.baseUrl).port;
        final r = await _system.run(lms, ['server', 'start', '--port', '$port']);
        if (r == null || r.code != 0) return "LM Studio didn't start its server: ${r?.out.trim() ?? 'lms failed'}";
        _lmsOurs = true;
      case _ when server.manual && (server.startCommand ?? '').trim().isNotEmpty:
        launched = await _system.launch(
          server.id,
          server.startCommand!.trim(),
          const [],
          shell: true,
          logPath: logDir == null ? null : '$logDir/${server.id.replaceAll(':', '-')}.log',
        );
      case _:
        return "EveryAI can't start ${server.label}: start it the way you usually do.";
    }
    if (server.kind != LocalServerKind.lmstudio && launched == null) {
      return _system.launchProblem ?? "Couldn't start it.";
    }
    // Ready when it answers; an early exit ends the wait with the reason.
    int? exitCode;
    if (launched != null) {
      unawaited(
        launched.exited.then((code) {
          exitCode = code;
          // A server that ends later (crash, killed elsewhere) is seen down at once.
          if (ref.mounted) {
            _apply(server.id, const SeenDown());
            if (server.kind == LocalServerKind.fm) ref.read(fmPortProvider.notifier).set(null);
          }
        }),
      );
    }
    final port = server.kind == LocalServerKind.fm ? ref.read(fmPortProvider) : Uri.parse(server.baseUrl).port;
    final until = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(until)) {
      if (exitCode != null) return 'It stopped right after starting (exit $exitCode). See its log in $logDir.';
      if (state[server.id] is! ServerStarting) return null; // Called off by a stop.
      if (await _answers(server, port)) {
        _apply(server.id, const Started(ServerOwner.everyai));
        return null;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    await _system.stopOwned(server.id, grace: const Duration(seconds: 2));
    return "It didn't answer within 30 seconds.";
  }

  Future<bool> _answers(LocalServer server, int? port) async {
    if (port == null || port == 0) return false;
    final path = switch (server.kind) {
      LocalServerKind.ollama => '/api/version',
      LocalServerKind.fm => '/health',
      _ => '${Uri.parse(server.baseUrl).path}/models',
    };
    final uri = Uri.parse(server.baseUrl).replace(port: port, path: path);
    return (await _http.get(uri, timeout: const Duration(seconds: 2)))?.ok ?? false;
  }

  Future<String?> _stop(LocalServer server) async {
    if (!_apply(server.id, const StopAsked())) return 'It is not running.';
    String? reason;
    if (_system.owns(server.id)) {
      reason = await _system.stopOwned(server.id);
    } else if (server.kind == LocalServerKind.lmstudio && await ref.read(lmsPathProvider.future) != null) {
      final r = await _system.run((await ref.read(lmsPathProvider.future))!, const ['server', 'stop']);
      reason = r == null || r.code != 0 ? "LM Studio didn't stop its server: ${r?.out.trim() ?? 'lms failed'}" : null;
      if (reason == null) _lmsOurs = false;
    } else {
      final port = Uri.parse(server.baseUrl).port;
      reason = port <= 0 ? 'It has no port.' : await _system.stopListener(port);
    }
    if (reason == null) {
      final port = server.kind == LocalServerKind.fm ? ref.read(fmPortProvider) : Uri.parse(server.baseUrl).port;
      final until = DateTime.now().add(const Duration(seconds: 5));
      while (await _answers(server, port)) {
        if (DateTime.now().isAfter(until)) {
          reason = 'It still answers.';
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    if (reason != null) {
      _apply(server.id, StopFailed(reason));
      return reason;
    }
    _apply(server.id, const StopDone());
    if (server.kind == LocalServerKind.fm) {
      ref.read(fmPortProvider.notifier).set(null);
      // The user stopped Apple's server: it no longer starts by itself.
      ref.read(preferencesProvider)[fmAutostartKey] = '0';
    }
    await ref.read(localServersProvider.notifier).refresh();
    return null;
  }

  /// Quit: every server EveryAI started ends (servers the user started are left running).
  Future<void> stopOwned() async {
    await _system.stopAllOwned();
    if (_lmsOurs) {
      final lms = await ref.read(lmsPathProvider.future);
      if (lms != null) await _system.run(lms, const ['server', 'stop']);
      _lmsOurs = false;
    }
  }
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
