import 'dart:async';
import 'dart:convert';

import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/preferences.dart';
import '../../core/providers.dart';
import '../models/domain/model_catalog.dart';
import '../models/models_providers.dart';
import '../usage/usage_totals.dart';
import 'domain/agent_mode.dart';
import 'domain/code_session.dart';
import 'domain/questions.dart';
import 'domain/transcript.dart';
import 'harness/events.dart';
import 'harness/fake_harness.dart';
import 'harness/harness.dart';
import 'harness/openhands_harness.dart';
import 'sidecar/sidecar.dart';

/// Projects under this scheme run on the scripted [FakeHarness].
const demoScheme = 'demo://';

bool isDemoPath(String path) => path.startsWith(demoScheme);

/// The scripted harness for demo projects.
final harnessProvider = Provider<Harness>((ref) => FakeHarness());

/// The local OpenHands agent-server, started on first use and stopped with
/// the app.
final sidecarProvider = Provider<Sidecar>((ref) {
  final sidecar = createSidecar();
  // Provider disposal doesn't run on quit; stop the server when the app exits.
  final lifecycle = AppLifecycleListener(
    onExitRequested: () async {
      await sidecar.stop();
      return AppExitResponse.exit;
    },
    onDetach: sidecar.stop,
  );
  ref.onDispose(() {
    lifecycle.dispose();
    unawaited(sidecar.stop());
  });
  return sidecar;
});

/// The harness a session in [workingDir] runs on: the scripted one for demo
/// projects, else the sidecar (started, or restarted after a crash, on demand).
Future<Harness> harnessFor(Ref ref, String workingDir) async {
  if (isDemoPath(workingDir)) return ref.read(harnessProvider);
  final endpoint = await ref.read(sidecarProvider).endpoint();
  return OpenHandsHarness(baseUrl: endpoint.baseUrl, sessionApiKey: endpoint.sessionApiKey);
}

/// The user's `sk-eai-` key for the backend's OpenAI-compatible gateway; the
/// agent-server sends its LLM calls there. Minted once, then kept.
Future<String> gatewayKey(Ref ref) async {
  const prefKey = 'code.gateway_key';
  final prefs = ref.read(preferencesProvider);
  if (prefs[prefKey] case final key? when key.isNotEmpty) return key;
  // Dev builds skip sign-in; the backend's DEV_AUTH treats them as its dev user.
  final authenticated = !ref.read(appConfigProvider).devSkipAuth;
  final res = await ref.read(apiClientProvider).postJson('v1/keys', {
    'name': 'EveryAI Code',
  }, authenticated: authenticated);
  final key = res['key']! as String;
  prefs[prefKey] = key;
  return key;
}

/// Sessions started in this run of the app, by session id.
final _liveProvider = Provider<Map<String, HarnessSession>>((ref) => {});

/// Folders the user opened as projects (stored in preferences).
final codeProjectsProvider = NotifierProvider<CodeProjects, List<CodeProject>>(CodeProjects.new);

final class CodeProjects extends Notifier<List<CodeProject>> {
  static const _key = 'code.projects';

  @override
  List<CodeProject> build() {
    final raw = ref.read(preferencesProvider)[_key];
    if (raw == null) return const [];
    return [for (final p in jsonDecode(raw) as List<Object?>) CodeProject.fromJson(p! as Map<String, Object?>)];
  }

  void _save() => ref.read(preferencesProvider)[_key] = jsonEncode([for (final p in state) p.toJson()]);

  CodeProject add(String path, {String? name}) {
    final existing = state.where((p) => p.path == path).firstOrNull;
    if (existing != null) return existing;
    final project = CodeProject(
      id: const Uuid().v7(),
      name: name ?? path.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).lastOrNull ?? path,
      path: path,
    );
    state = [project, ...state];
    _save();
    return project;
  }

  void remove(String id) {
    state = [
      for (final p in state)
        if (p.id != id) p,
    ];
    _save();
  }
}

/// Every coding session, newest first (stored in preferences; transcripts
/// live in the agent server).
final codeSessionsProvider = NotifierProvider<CodeSessions, List<CodeSessionInfo>>(CodeSessions.new);

final class CodeSessions extends Notifier<List<CodeSessionInfo>> {
  static const _key = 'code.sessions';

  @override
  List<CodeSessionInfo> build() {
    final raw = ref.read(preferencesProvider)[_key];
    if (raw == null) return const [];
    return [for (final s in jsonDecode(raw) as List<Object?>) CodeSessionInfo.fromJson(s! as Map<String, Object?>)];
  }

  void _save() => ref.read(preferencesProvider)[_key] = jsonEncode([for (final s in state) s.toJson()]);

  CodeSessionInfo? byId(String id) => state.where((s) => s.id == id).firstOrNull;

  /// Starts a session on [project] with [prompt] as the first message.
  Future<CodeSessionInfo> start({
    required CodeProject project,
    required String prompt,
    required String model,
    required AgentMode mode,
  }) async {
    final id = const Uuid().v7();
    final demo = isDemoPath(project.path);
    final harness = await harnessFor(ref, project.path);
    final live = await harness.start(
      SessionSpec(
        workingDir: project.path,
        model: model,
        mode: mode,
        llmBaseUrl: demo ? '' : ref.read(appConfigProvider).apiBaseUrl.resolve('v1').toString(),
        llmApiKey: demo ? '' : await gatewayKey(ref),
        sessionTag: id,
        initialMessage: prompt,
        maxInputTokens: ref.read(modelCatalogProvider)[ModelId(model)]?.contextLength,
      ),
    );
    ref.read(_liveProvider)[id] = live;
    final info = CodeSessionInfo(
      id: id,
      projectId: project.id,
      title: titleFor(prompt),
      conversationId: live.id,
      model: model,
      mode: mode,
      workingDir: project.path,
      createdAt: DateTime.now(),
    );
    state = [info, ...state];
    _save();
    return info;
  }

  void update(CodeSessionInfo info) {
    state = [for (final s in state) s.id == info.id ? info : s];
    _save();
  }

  void remove(String id) {
    unawaited(ref.read(_liveProvider).remove(id)?.close());
    state = [
      for (final s in state)
        if (s.id != id) s,
    ];
    _save();
  }

  static String titleFor(String prompt) {
    final line = prompt.trim().split('\n').first;
    return line.length <= 48 ? line : '${line.substring(0, line.lastIndexOf(' ', 48).clamp(24, 48))}…';
  }
}

@immutable
final class CodeSessionState {
  const CodeSessionState({
    this.transcript = const Transcript(),
    this.mode = AgentMode.ask,
    this.queued = const [],
    this.connected = false,
    this.error,
  });

  final Transcript transcript;
  final AgentMode mode;

  /// Messages typed while the agent was busy; sent when it stops.
  final List<String> queued;
  final bool connected;
  final String? error;

  SessionStatus get status => switch (transcript) {
    _ when error != null => SessionStatus.failed,
    Transcript(pending: [_, ...]) => SessionStatus.needsInput,
    final t when t.openQuestion != null => SessionStatus.needsInput,
    Transcript(status: ExecutionStatus.running) => SessionStatus.running,
    Transcript(status: ExecutionStatus.error || ExecutionStatus.stuck) => SessionStatus.failed,
    Transcript(status: ExecutionStatus.finished) => SessionStatus.done,
    _ when !connected => SessionStatus.starting,
    _ => SessionStatus.idle,
  };

  CodeSessionState copyWith({
    Transcript? transcript,
    AgentMode? mode,
    List<String>? queued,
    bool? connected,
    String? error,
  }) => CodeSessionState(
    transcript: transcript ?? this.transcript,
    mode: mode ?? this.mode,
    queued: queued ?? this.queued,
    connected: connected ?? this.connected,
    error: error ?? this.error,
  );
}

/// One session's live state; talks to the harness.
final codeSessionProvider = NotifierProvider.family<CodeSessionController, CodeSessionState, String>(
  CodeSessionController.new,
);

final class CodeSessionController extends Notifier<CodeSessionState> {
  CodeSessionController(this.sessionId);
  final String sessionId;

  HarnessSession? _session;
  StreamSubscription<HarnessEvent>? _sub;
  final _builder = TranscriptBuilder();

  /// The approval set we already answered (so one prompt gets one answer).
  String _answered = '';

  @override
  CodeSessionState build() {
    final info = ref.read(codeSessionsProvider.notifier).byId(sessionId);
    ref.onDispose(() => _sub?.cancel());
    // After build returns, so the connected flag isn't overwritten.
    if (info != null) unawaited(Future.microtask(() => _connect(info)));
    return CodeSessionState(mode: info?.mode ?? AgentMode.ask);
  }

  Future<void> _connect(CodeSessionInfo info) async {
    try {
      final live = ref.read(_liveProvider);
      final session = _session =
          live[sessionId] ?? await (await harnessFor(ref, info.workingDir)).attach(info.conversationId);
      live[sessionId] = session;
      _sub = session.events.listen(_onEvent);
      state = state.copyWith(connected: true);
    } on Object catch (e) {
      state = state.copyWith(error: '$e');
    }
  }

  void _onEvent(HarnessEvent event) {
    // OpenHands reports `stats` after every model call; the cost lives in our ledger.
    if (event is StateChange) ref.read(codeUsageProvider(sessionId).notifier).refreshSoon();
    _builder.add(event);
    final transcript = _builder.snapshot;
    state = state.copyWith(transcript: transcript);
    _autoRespond(transcript);
    if (!transcript.running && transcript.pending.isEmpty && state.queued.isNotEmpty) {
      final [next, ...rest] = state.queued;
      state = state.copyWith(queued: rest);
      unawaited(_session?.send(next));
    }
  }

  /// Approves or refuses pending actions the mode decides on its own.
  void _autoRespond(Transcript t) {
    if (t.pending.isEmpty) return;
    final key = t.pending.map((c) => c.id).join(',');
    if (key == _answered) return;
    final mode = state.mode;
    if (t.pending.any(mode.rejects)) {
      _answered = key;
      unawaited(
        _session?.respond(
          accept: false,
          reason: 'Plan mode is read-only. Finish the plan and wait for the user to start building.',
        ),
      );
    } else if (t.pending.every(mode.autoApproves)) {
      _answered = key;
      unawaited(_session?.respond(accept: true));
    }
  }

  /// Sends [text], or queues it while the agent is busy.
  Future<void> send(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    if (state.transcript.running || state.transcript.pending.isNotEmpty) {
      state = state.copyWith(queued: [...state.queued, t]);
      return;
    }
    await _session?.send(t);
  }

  /// Interrupts the agent and sends [text] right away.
  Future<void> steer(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    await _session?.interrupt();
    await _session?.send(t);
  }

  void unqueue(int index) => state = state.copyWith(queued: [...state.queued]..removeAt(index));

  Future<void> stop() async {
    state = state.copyWith(queued: const []);
    await _session?.interrupt();
  }

  Future<void> approve() async {
    _answered = state.transcript.pending.map((c) => c.id).join(',');
    await _session?.respond(accept: true);
  }

  Future<void> deny([String? reason]) async {
    _answered = state.transcript.pending.map((c) => c.id).join(',');
    await _session?.respond(accept: false, reason: reason?.trim().isEmpty ?? true ? null : reason);
  }

  Future<void> answer(QuestionItem item, List<QuestionAnswer> answers) =>
      _session?.send(answersMessage(item.questions, answers)) ?? Future.value();

  Future<void> setMode(AgentMode mode) async {
    state = state.copyWith(mode: mode);
    final sessions = ref.read(codeSessionsProvider.notifier);
    if (sessions.byId(sessionId) case final info?) sessions.update(info.copyWith(mode: mode));
    await _session?.setMode(mode);
    _answered = '';
    _autoRespond(state.transcript);
  }

  /// Plan mode → Auto-edit, and tell the agent to go.
  Future<void> startBuilding() async {
    await setMode(AgentMode.autoEdit);
    await send('The plan looks good. Go ahead and build it.');
  }
}

/// Tokens and spend of a Code session, from the backend's ledger (the gateway
/// attributes every model call to the session). Demo sessions have none.
final codeUsageProvider = AsyncNotifierProvider.family<CodeUsage, UsageTotals, String>(CodeUsage.new);

final class CodeUsage extends AsyncNotifier<UsageTotals> {
  CodeUsage(this.sessionId);
  final String sessionId;
  Timer? _debounce;

  @override
  Future<UsageTotals> build() async {
    ref.onDispose(() => _debounce?.cancel());
    final info = ref.read(codeSessionsProvider.notifier).byId(sessionId);
    if (info == null || isDemoPath(info.workingDir)) return UsageTotals.zero;
    final json = await ref
        .read(apiClientProvider)
        .getJson('v1/usage/session/$sessionId', authenticated: !ref.read(appConfigProvider).devSkipAuth);
    return UsageTotals.fromJson(json);
  }

  /// Refetches once events go quiet for a second.
  void refreshSoon() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 1), () async {
      final next = await AsyncValue.guard(build);
      // Keep the last reading if the server can't be reached.
      if (ref.mounted && next.hasValue) state = next;
    });
  }
}
