import 'dart:async';
import 'dart:convert';

import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/preferences.dart';
import '../../core/providers.dart';
import '../attachments/attachment.dart';
import '../models/domain/model_catalog.dart';
import '../models/models_providers.dart';
import '../usage/usage_totals.dart';
import 'domain/agent_mode.dart';
import 'domain/code_session.dart';
import 'domain/questions.dart';
import 'domain/transcript.dart';
import 'git/git_service.dart';
import 'harness/events.dart';
import 'harness/fake_harness.dart';
import 'harness/harness.dart';
import 'harness/openhands_harness.dart';
import 'harness/session_processes.dart';
import 'permissions_providers.dart';
import 'settings/context_files.dart';
import 'settings/settings.dart';
import 'sidecar/sidecar.dart';
import 'uploads/uploads.dart';

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
  return ref.read(_sidecarHarnessProvider);
}

/// One harness for the sidecar; it asks the sidecar where it is on every
/// call, which also restarts a server that died.
final _sidecarHarnessProvider = Provider<Harness>((ref) {
  final sidecar = ref.read(sidecarProvider);
  return OpenHandsHarness.located(() async {
    final e = await sidecar.endpoint();
    return (e.baseUrl, e.sessionApiKey);
  });
});

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

/// A user message on its way to the agent: text (with the attachments note)
/// and the images the model can see.
@immutable
final class Outgoing {
  const Outgoing(this.text, {this.images = const []});
  final String text;
  final List<String> images;
}

bool _sees(Ref ref, String model) =>
    ref.read(modelCatalogProvider)[ModelId(model)]?.accepts(AttachmentKind.image) ?? false;

/// Saves [files] into the project and builds the message that points the agent
/// at them. Demo projects have no folder: the note alone.
Future<Outgoing> prepareMessage(
  Ref ref, {
  required String text,
  required String workingDir,
  required String model,
  List<Attachment> files = const [],
}) async {
  if (files.isEmpty) return Outgoing(text);
  final paths = isDemoPath(workingDir) ? [for (final f in files) f.name] : await saveUploads(workingDir, files);
  final note = attachedNote(paths);
  return Outgoing(
    text.isEmpty ? note : '$text\n\n$note',
    images: _sees(ref, model)
        ? [
            for (final f in files)
              if (f.kind == AttachmentKind.image) f.dataUrl,
          ]
        : const [],
  );
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

/// New sessions answer question cards and plans inside the held tool call,
/// so the agent keeps its turn (verified live: `tool/agent_eval/held_answers_test.dart`).
/// Build with `--dart-define=CODE_HELD_ANSWERS=false` to send replies as new
/// user messages instead.
const heldAnswers = bool.fromEnvironment('CODE_HELD_ANSWERS', defaultValue: true);

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
    String? effort,
    List<Attachment> files = const [],
  }) async {
    final id = const Uuid().v7();
    final demo = isDemoPath(project.path);
    final title = titleFor(prompt.isEmpty ? files.first.name : prompt);
    final worktree = demo ? null : await _worktreeFor(project, title, id);
    final workingDir = worktree?.path ?? project.path;
    final first = await prepareMessage(ref, text: prompt, workingDir: workingDir, model: model, files: files);
    final harness = await harnessFor(ref, project.path);
    // Settings and commit style come from the main checkout (local settings aren't in worktrees).
    final agentPrompt = demo ? null : await agentPromptFor(project.path);
    // AGENTS.md and friends from the project folder up to the repository root (OpenHands doesn't load them).
    final context = demo ? const <ContextFile>[] : await _startContext(workingDir, project.path);
    // The scripted demo approves client tools like the old path does.
    final hold = heldAnswers && !demo;
    final live = await harness.start(
      SessionSpec(
        workingDir: workingDir,
        model: model,
        mode: mode,
        llmBaseUrl: demo ? '' : ref.read(appConfigProvider).apiBaseUrl.resolve('v1').toString(),
        llmApiKey: demo ? '' : await gatewayKey(ref),
        sessionTag: id,
        initialMessage: modeNote(mode, first.text),
        initialImages: first.images,
        vision: _sees(ref, model),
        maxInputTokens: ref.read(modelCatalogProvider)[ModelId(model)]?.contextLength,
        persona: agentPrompt?.persona,
        promptSuffix: agentPrompt == null ? null : withProjectContext(agentPrompt.suffix, context),
        effort: effort,
        holdClientTools: hold,
      ),
    );
    ref.read(_liveProvider)[id] = live;
    final info = CodeSessionInfo(
      id: id,
      projectId: project.id,
      title: title,
      conversationId: live.id,
      model: model,
      mode: mode,
      workingDir: workingDir,
      createdAt: DateTime.now(),
      branch: worktree?.branch ?? '',
      worktree: worktree,
      effort: effort ?? '',
      holdClientTools: hold,
    );
    state = [info, ...state];
    _save();
    return info;
  }

  static Future<List<ContextFile>> _startContext(String workingDir, String projectDir) async {
    try {
      return await (await ProjectContext.forSession(workingDir: workingDir, projectDir: projectDir)).atStart();
    } on Object {
      return const [];
    }
  }

  /// A worktree for the session when [project] is a git repository.
  static Future<SessionWorktree?> _worktreeFor(CodeProject project, String title, String id) async {
    final root = await GitService.repoRoot(project.path);
    if (root == null) return null;
    final data = await GitService.dataDir();
    final repoName = root.split('/').last;
    return GitService.createWorktree(
      repoRoot: root,
      slug: sessionSlug(title, id),
      worktreesDir: '$data/worktrees/$repoName-${project.id.substring(project.id.length - 6)}',
      hooksDir: '$data/git-hooks',
    );
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
  final List<Outgoing> queued;
  final bool connected;
  final String? error;

  SessionStatus get status => switch (transcript) {
    _ when error != null => SessionStatus.failed,
    Transcript(pending: [_, ...]) => SessionStatus.needsInput,
    final t when t.openQuestion != null || t.openPlan != null => SessionStatus.needsInput,
    Transcript(status: ExecutionStatus.running) => SessionStatus.running,
    Transcript(status: ExecutionStatus.error || ExecutionStatus.stuck) => SessionStatus.failed,
    Transcript(status: ExecutionStatus.finished) => SessionStatus.done,
    _ when !connected => SessionStatus.starting,
    _ => SessionStatus.idle,
  };

  CodeSessionState copyWith({
    Transcript? transcript,
    AgentMode? mode,
    List<Outgoing>? queued,
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

  /// Patterns approved "for this session" on the approval card.
  final _sessionAllowed = <String>{};

  /// Permission rules from the project's `settings.json` files.
  PermissionRules _settingsRules = PermissionRules.none;

  /// The project's instruction files; nested ones go out with the next message.
  ProjectContext? _context;

  @override
  CodeSessionState build() {
    final info = ref.read(codeSessionsProvider.notifier).byId(sessionId);
    ref.onDispose(() {
      _sub?.cancel();
      _gitTimer?.cancel();
    });
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
      await _openContext(info);
      _sub = session.events.listen(_onEvent);
      state = state.copyWith(connected: true);
      await _loadSettingsRules(info);
    } on Object catch (e) {
      state = state.copyWith(error: '$e');
    }
  }

  /// Before the history replays, so files it shows delivered aren't sent again.
  Future<void> _openContext(CodeSessionInfo info) async {
    if (isDemoPath(info.workingDir)) return;
    final project = ref.read(codeProjectsProvider).where((p) => p.id == info.projectId).firstOrNull;
    try {
      final c = await ProjectContext.forSession(
        workingDir: info.workingDir,
        projectDir: project?.path ?? info.workingDir,
      );
      await c.atStart();
      _context = c;
    } on Object {
      // Without it, nested instruction files just aren't delivered.
    }
  }

  Future<void> _loadSettingsRules(CodeSessionInfo info) async {
    if (isDemoPath(info.workingDir)) return;
    final project = ref.read(codeProjectsProvider).where((p) => p.id == info.projectId).firstOrNull;
    try {
      final s = await loadAgentSettings(project?.path ?? info.workingDir);
      _settingsRules = PermissionRules(allow: s.allow, deny: s.deny);
    } on Object {
      return;
    }
    if (!ref.mounted) return;
    _answered = '';
    _autoRespond(state.transcript);
  }

  /// What decides this session's actions: stored rules (global, project),
  /// then `settings.json` rules, plus approvals remembered for the session.
  PermissionPolicy get policy {
    final info = ref.read(codeSessionsProvider.notifier).byId(sessionId);
    return PermissionPolicy(
      rules: ref.read(codePermissionsProvider).rulesFor(info?.projectId) + _settingsRules,
      session: {..._sessionAllowed},
      workingDir: info == null || isDemoPath(info.workingDir) ? null : info.workingDir,
    );
  }

  void _onEvent(HarnessEvent event) {
    if (event is ConnectionChange) {
      state = state.copyWith(connected: event.connected);
      return;
    }
    // OpenHands reports `stats` after every model call; the cost lives in our ledger.
    if (event is StateChange) ref.read(codeUsageProvider(sessionId).notifier).refreshSoon();
    final wasRunning = state.transcript.running;
    _trackContext(event);
    _builder.add(event);
    final transcript = _builder.snapshot;
    state = state.copyWith(transcript: transcript);
    // Edits and commands change files: refresh Changes as they land, not just at turn end.
    if (event is ToolResult && editsFiles(event.toolName)) _refreshGitSoon();
    if (wasRunning && !transcript.running) {
      _refreshGitSoon();
      // The ledger can trail the last model call, so read it again once it settles.
      ref.read(codeUsageProvider(sessionId).notifier)
        ..refreshSoon(delay: const Duration(milliseconds: 300))
        ..refreshSoon(delay: const Duration(seconds: 4), force: true);
    }
    _autoRespond(transcript);
    if (!transcript.running && transcript.pending.isEmpty && state.queued.isNotEmpty) {
      final [next, ...rest] = state.queued;
      state = state.copyWith(queued: rest);
      unawaited(_checkpoint().then((_) => _sendNow(next)));
    }
  }

  void _trackContext(HarnessEvent event) {
    final c = _context;
    if (c == null) return;
    switch (event) {
      case ActionCall():
        unawaited(c.touch(event).catchError((Object _) {}));
      case ChatMessage(fromUser: true, :final text):
        final (paths, _) = splitContextNotes(splitModeNote(text).$2);
        if (paths.isNotEmpty) c.delivered(paths);
      default:
        break;
    }
  }

  Timer? _gitTimer;

  /// Coalesces bursts of edits into one `git diff`.
  void _refreshGitSoon() {
    if (_gitTimer?.isActive ?? false) return;
    _gitTimer = Timer(const Duration(milliseconds: 400), () {
      if (ref.mounted && ref.exists(codeGitProvider(sessionId))) {
        unawaited(ref.read(codeGitProvider(sessionId).notifier).refresh());
      }
    });
  }

  /// Whether this session answers cards and plans inside the held call.
  bool get _holds => ref.read(codeSessionsProvider.notifier).byId(sessionId)?.holdClientTools ?? false;

  /// Approves or refuses pending actions the mode decides on its own.
  void _autoRespond(Transcript t) {
    // A held card or plan waits for the user (one answer covers every
    // pending action, so the rest wait with it); sessions that don't hold
    // them approve them at once, as the agent ends its turn after the call.
    if (t.held.isNotEmpty && _holds) return;
    final waiting = [...t.pending, ...t.held];
    if (waiting.isEmpty) return;
    final key = waiting.map((c) => c.id).join(',');
    if (key == _answered) return;
    final verdict = policy.decideAll(waiting, state.mode);
    if (verdict == null) return;
    _answered = key;
    final session = _session;
    if (verdict.accept) {
      unawaited(session?.respond(accept: true));
    } else {
      // The server parks the conversation after a rejection; run it again so
      // the agent reads the refusal (Plan mode, the safety floor, a deny
      // rule) and carries on (a user's own "No" still stops it).
      unawaited(session?.respond(accept: false, reason: verdict.reason).then((_) => session.resume()));
    }
  }

  /// Snapshots the worktree before the next user turn, so "Restore files"
  /// can bring it back. Turn 1 needs none: it's the base commit.
  Future<void> _checkpoint() async {
    final w = ref.read(codeSessionsProvider.notifier).byId(sessionId)?.worktree;
    final turn = state.transcript.items.whereType<UserTurn>().length + 1;
    if (w == null || turn < 2) return;
    try {
      await GitService.checkpoint(w, turn);
    } on Object {
      // A missing checkpoint only disables rewinding to this turn.
    }
  }

  /// [text] with a mode note: the full one after a mode change, else a short reminder.
  /// Nested instruction files found since the last message go first, after the mode note.
  String _noted(String text) {
    final told = state.transcript.notedMode;
    final context = _context?.takeNote() ?? '';
    final body = context.isEmpty ? text : (text.isEmpty ? context : '$context\n\n$text');
    return modeNote(state.mode, body, full: told != state.mode, from: told);
  }

  Future<Outgoing?> _outgoing(String text, List<Attachment> files) async {
    final t = text.trim();
    if (t.isEmpty && files.isEmpty) return null;
    final info = ref.read(codeSessionsProvider.notifier).byId(sessionId);
    if (info == null) return Outgoing(t);
    try {
      return await prepareMessage(ref, text: t, workingDir: info.workingDir, model: info.model, files: files);
    } on Object catch (e) {
      state = state.copyWith(error: "Couldn't save the attachments: $e");
      return null;
    }
  }

  /// Sends [text] (and [files], saved into the project), or queues it while the agent is busy.
  Future<void> send(String text, {List<Attachment> files = const []}) async {
    final out = await _outgoing(text, files);
    if (out == null) return;
    if (state.transcript.running || state.transcript.pending.isNotEmpty) {
      state = state.copyWith(queued: [...state.queued, out]);
      return;
    }
    await _checkpoint();
    await _sendNow(out);
  }

  /// Sends [out]. A card or plan still held for the user is closed first: the
  /// call's result says the user replied in chat, and the message follows.
  Future<void> _sendNow(Outgoing out) async {
    final session = _session;
    if (session == null) return;
    final held = state.transcript.held;
    if (held.isNotEmpty) {
      _answered = [...state.transcript.pending, ...held].map((c) => c.id).join(',');
      final plan = held.any((c) => c.toolName == presentPlanTool);
      await session.respond(accept: false, reason: plan ? '$planRevisionLead see their next message.' : repliedInChat);
    }
    await session.send(_noted(out.text), images: out.images);
  }

  /// Interrupts the agent and sends [text] right away.
  Future<void> steer(String text, {List<Attachment> files = const []}) async {
    final out = await _outgoing(text, files);
    if (out == null) return;
    await _session?.interrupt();
    await _checkpoint();
    await _sendNow(out);
  }

  void unqueue(int index) => state = state.copyWith(queued: [...state.queued]..removeAt(index));

  /// Runs the agent again after a failed turn (a dropped connection, an
  /// upstream error); the conversation keeps everything so far. A stuck
  /// agent needs a new message: the server's stuck check reads the history
  /// and would stop a plain re-run at once.
  Future<void> retry() async {
    if (state.transcript.status == ExecutionStatus.stuck) return send('Carry on from where you stopped.');
    await _session?.resume();
  }

  Future<void> stop() async {
    state = state.copyWith(queued: const []);
    final pending = state.transcript.pending;
    if (pending.isNotEmpty) {
      _answered = [...pending, ...state.transcript.held].map((c) => c.id).join(',');
      await _session?.respond(accept: false, reason: denialMessage(DenialKind.cancelled));
    }
    // Ctrl-C reaches only the terminal's foreground command; background jobs,
    // servers and commands left running after a timeout are ended here.
    final info = ref.read(codeSessionsProvider.notifier).byId(sessionId);
    await Future.wait([
      ?_session?.interrupt(),
      if (info != null && !isDemoPath(info.workingDir))
        killSessionProcesses(tag: info.id, workingDir: info.workingDir, ownsDir: info.worktree != null),
    ]);
  }

  /// The rules "allow for this session" / "always allow" would store for
  /// the pending actions, or null when any of them can't be remembered
  /// (compound commands, dangerous actions).
  List<String>? rememberable() {
    final pending = state.transcript.pending;
    if (pending.isEmpty) return null;
    final dir = policy.workingDir;
    final patterns = [for (final c in pending) rememberPattern(c, workingDir: dir)];
    if (patterns.any((p) => p == null)) return null;
    return {for (final p in patterns) p!}.toList();
  }

  /// Approves the pending actions; with [scope] session or always, also
  /// what [rememberable] gives, so the same commands run without asking.
  Future<void> approve([ApprovalScope scope = ApprovalScope.once]) async {
    if (scope != ApprovalScope.once) {
      final patterns = rememberable() ?? const <String>[];
      if (scope == ApprovalScope.session) {
        _sessionAllowed.addAll(patterns);
      } else {
        final projectId = ref.read(codeSessionsProvider.notifier).byId(sessionId)?.projectId;
        final store = ref.read(codePermissionsProvider.notifier);
        for (final p in patterns) {
          store.allow(p, projectId: projectId);
        }
      }
    }
    _answered = state.transcript.pending.map((c) => c.id).join(',');
    await _session?.respond(accept: true);
  }

  /// Refuses the pending actions; the agent reads the fixed denial text
  /// with [reason] word for word.
  Future<void> deny([String? reason]) async {
    _answered = state.transcript.pending.map((c) => c.id).join(',');
    await _session?.respond(accept: false, reason: denialMessage(DenialKind.denied, reason: reason));
  }

  /// Sends the card's answers: as the held call's result when the server is
  /// holding it, else as a new user message.
  Future<void> answer(QuestionItem item, List<QuestionAnswer> answers) async {
    final session = _session;
    if (session == null) return;
    if (_isHeld(item.call)) {
      await _replyInCall(session, answersReason(item.questions, answers));
    } else {
      await session.send(_noted(answersMessage(item.questions, answers)));
    }
  }

  bool _isHeld(ActionCall call) => state.transcript.held.any((c) => c.id == call.id);

  /// Rejects the held call(s) with [reason], which the agent reads as the
  /// call's result, then runs it again (a rejection parks the conversation).
  Future<void> _replyInCall(HarnessSession session, String reason) async {
    _answered = [...state.transcript.pending, ...state.transcript.held].map((c) => c.id).join(',');
    await session.respond(accept: false, reason: reason);
    await session.resume();
  }

  Future<void> setMode(AgentMode mode) async {
    state = state.copyWith(mode: mode);
    final sessions = ref.read(codeSessionsProvider.notifier);
    if (sessions.byId(sessionId) case final info?) sessions.update(info.copyWith(mode: mode));
    await _session?.setMode(mode, holdClientTools: _holds);
    _answered = '';
    _autoRespond(state.transcript);
  }

  /// Approves the plan and tells the agent to go; Plan mode moves to Auto-edit.
  Future<void> startBuilding() async {
    final held = state.transcript.openPlan?.call;
    if (state.mode == AgentMode.plan) await setMode(AgentMode.autoEdit);
    final session = _session;
    if (session != null && held != null && _isHeld(held)) {
      await _replyInCall(session, planApprovedReason);
    } else {
      await send(planApprovedMessage);
    }
  }
}

/// What the agent server reports for sessions whose view isn't open (they
/// have no live controller), refreshed every 10 s while a list shows them.
final codeStatusesProvider = NotifierProvider.autoDispose<CodeStatuses, Map<String, SessionStatus>>(CodeStatuses.new);

final class CodeStatuses extends Notifier<Map<String, SessionStatus>> {
  Timer? _timer;

  @override
  Map<String, SessionStatus> build() {
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => unawaited(_refresh()));
    ref.onDispose(() => _timer?.cancel());
    unawaited(Future.microtask(_refresh));
    return const {};
  }

  Future<void> _refresh() async {
    final sessions = [
      for (final s in ref.read(codeSessionsProvider))
        if (!isDemoPath(s.workingDir)) s,
    ];
    if (sessions.isEmpty) return;
    try {
      final byConversation = await ref.read(_sidecarHarnessProvider).statuses([
        for (final s in sessions) s.conversationId,
      ]);
      if (!ref.mounted) return;
      state = {
        for (final s in sessions)
          if (byConversation[s.conversationId] case final status?) s.id: _sessionStatus(status),
      };
    } on Object {
      // The server isn't up yet; try again on the next tick.
    }
  }

  static SessionStatus _sessionStatus(ExecutionStatus s) => switch (s) {
    ExecutionStatus.running => SessionStatus.running,
    ExecutionStatus.waitingForConfirmation => SessionStatus.needsInput,
    ExecutionStatus.finished => SessionStatus.done,
    ExecutionStatus.error || ExecutionStatus.stuck => SessionStatus.failed,
    _ => SessionStatus.idle,
  };
}

/// Tools that can change the worktree (file edits, shell commands).
bool editsFiles(String toolName) =>
    const {'file_editor', 'terminal', 'str_replace_editor', 'apply_patch'}.contains(toolName);

/// Tokens and spend of a Code session, from the backend's ledger (the gateway
/// attributes every model call to the session). Demo sessions have none.
final codeUsageProvider = AsyncNotifierProvider.family<CodeUsage, UsageTotals, String>(CodeUsage.new);

final class CodeUsage extends AsyncNotifier<UsageTotals> {
  CodeUsage(this.sessionId);
  final String sessionId;
  Timer? _debounce;

  @override
  Future<UsageTotals> build() async {
    ref.onDispose(() {
      _debounce?.cancel();
      _later?.cancel();
    });
    return _fetch();
  }

  Future<UsageTotals> _fetch() async {
    final info = ref.read(codeSessionsProvider.notifier).byId(sessionId);
    if (info == null || isDemoPath(info.workingDir)) return UsageTotals.zero;
    final json = await ref
        .read(apiClientProvider)
        .getJson('v1/usage/session/$sessionId', authenticated: !ref.read(appConfigProvider).devSkipAuth);
    return UsageTotals.fromJson(json);
  }

  Timer? _later;

  /// Refetches within [delay]. Calls while one is waiting join it (a steady
  /// stream of events must not push the reading back forever); [force] queues
  /// an extra, later read.
  void refreshSoon({Duration delay = const Duration(seconds: 1), bool force = false}) {
    if (force) {
      _later?.cancel();
      _later = Timer(delay, _read);
      return;
    }
    if (_debounce?.isActive ?? false) return;
    _debounce = Timer(delay, _read);
  }

  Future<void> _read() async {
    if (!ref.mounted) return;
    final next = await AsyncValue.guard(_fetch);
    // Keep the last reading if the server can't be reached.
    if (ref.mounted && next.hasValue) state = next;
  }
}

/// A session's changes since its base commit, for the header and Diff pane.
@immutable
final class GitSnapshot {
  const GitSnapshot({this.files = const [], this.ahead = 0, this.behind = 0});

  final List<FileDiff> files;

  /// Commits on the session branch / on the base branch since it forked.
  final int ahead;
  final int behind;

  int get added => files.fold(0, (n, f) => n + f.hunks.fold(0, (m, h) => m + h.added));
  int get removed => files.fold(0, (n, f) => n + f.hunks.fold(0, (m, h) => m + h.removed));
}

final codeGitProvider = AsyncNotifierProvider.family<CodeGit, GitSnapshot, String>(CodeGit.new);

/// The session's worktree: its diff, and what the user can do with it.
final class CodeGit extends AsyncNotifier<GitSnapshot> {
  CodeGit(this.sessionId);
  final String sessionId;

  CodeSessionInfo? get _info => ref.read(codeSessionsProvider.notifier).byId(sessionId);
  SessionWorktree get _w => _info?.worktree ?? (throw const GitError('This session has no git worktree.'));

  @override
  Future<GitSnapshot> build() => _load();

  Future<GitSnapshot> _load() async {
    final w = _info?.worktree;
    if (w == null) return const GitSnapshot();
    final (files, counts) = await (GitService.diff(w), GitService.aheadBehind(w)).wait;
    return GitSnapshot(files: files, ahead: counts.ahead, behind: counts.behind);
  }

  Future<void> refresh() async {
    final next = await AsyncValue.guard(_load);
    if (ref.mounted) state = next;
  }

  Future<void> revertHunk(FileDiff file, int hunk) async {
    await GitService.revertHunk(_w, file, hunk);
    await refresh();
  }

  /// Commits everything on the session branch; false when nothing changed.
  Future<bool> commit(String message) async {
    final done = await GitService.commitAll(_w, message);
    await refresh();
    return done;
  }

  /// Squashes the session onto its base branch in the main checkout.
  Future<String> squashMerge(String message) async {
    final sha = await GitService.squashMerge(_w, message);
    await refresh();
    return sha;
  }

  Future<void> push() => GitService.push(_w);

  Future<String> createPr({required String title, required String body}) async {
    await GitService.push(_w);
    return GitService.createPr(_w, title: title, body: body);
  }

  /// Puts the files back to how they were before user turn [turn] (1-based).
  Future<void> rewind(int turn) async {
    final w = _w;
    await GitService.restoreCheckpoint(w, turn <= 1 ? w.baseCommit : checkpointRef(w, turn));
    await refresh();
  }

  /// Removes the session, its worktree, branch and checkpoints.
  Future<void> discard() async {
    final w = _w;
    final data = await GitService.dataDir();
    ref.read(codeSessionsProvider.notifier).remove(sessionId);
    await GitService.removeWorktree(w, hooksDir: '$data/git-hooks');
  }
}

String checkpointRef(SessionWorktree w, int turn) => 'refs/everyai/${w.slug}/turn-$turn';
