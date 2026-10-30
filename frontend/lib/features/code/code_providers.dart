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
import 'domain/compaction.dart';
import 'domain/doom_loop.dart';
import 'domain/spill.dart';
import 'domain/subagents.dart';
import 'domain/questions.dart';
import 'domain/transcript.dart';
import 'git/git_service.dart';
import 'harness/events.dart';
import 'harness/fake_harness.dart';
import 'harness/harness.dart';
import 'harness/openhands_harness.dart';
import 'harness/session_processes.dart';
import 'harness/summarizer.dart';
import 'mcp_providers.dart';
import 'permissions_providers.dart';
import 'settings/context_files.dart';
import 'settings/settings.dart';
import 'sidecar/sidecar.dart';
import 'spill/spill.dart';
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

/// The backend's OpenAI-compatible gateway (`…/v1`), the agent's LLM provider.
String gatewayBaseUrl(Ref ref) => ref.read(appConfigProvider).apiBaseUrl.resolve('v1').toString();

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
    // The scripted demo approves client tools like the old path does.
    final hold = heldAnswers && !demo;
    final live = await harness.start(
      await specFor(
        sessionId: id,
        projectDir: project.path,
        workingDir: workingDir,
        model: model,
        mode: mode,
        effort: effort,
        holdClientTools: hold,
        initialMessage: modeNote(mode, first.text),
        initialImages: first.images,
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

  /// What a conversation for session [sessionId] starts with. A session
  /// that is compacted gets the same system prompt and tools again, so the
  /// model's cached prefix still holds.
  Future<SessionSpec> specFor({
    required String sessionId,
    required String projectDir,
    required String workingDir,
    required String model,
    required AgentMode mode,
    required bool holdClientTools,
    String? effort,
    String? initialMessage,
    List<String> initialImages = const [],
    bool runInitial = true,
    bool subagent = false,
    String? sessionTag,
  }) async {
    final demo = isDemoPath(projectDir);
    // Settings and commit style come from the main checkout (local settings aren't in worktrees).
    final agentPrompt = demo ? null : await agentPromptFor(projectDir);
    // AGENTS.md and friends from the project folder up to the repository root (OpenHands doesn't load them).
    final context = demo ? const <ContextFile>[] : await _startContext(workingDir, projectDir);
    // MCP servers come from the app's list (global plus this project's), never from repository files.
    final projectId = ref.read(codeProjectsProvider).where((p) => p.path == projectDir).firstOrNull?.id;
    final mcpConfig = demo ? const <String, Object?>{} : ref.read(codeMcpServersProvider).mcpConfigFor(projectId);
    return SessionSpec(
      workingDir: workingDir,
      model: model,
      mode: mode,
      llmBaseUrl: demo ? '' : gatewayBaseUrl(ref),
      llmApiKey: demo ? '' : await gatewayKey(ref),
      sessionTag: sessionTag ?? sessionId,
      initialMessage: initialMessage,
      initialImages: initialImages,
      runInitial: runInitial,
      vision: _sees(ref, model),
      maxInputTokens: ref.read(modelCatalogProvider)[ModelId(model)]?.contextLength,
      persona: agentPrompt?.persona,
      promptSuffix: agentPrompt == null ? null : withProjectContext(agentPrompt.suffix, context),
      effort: effort == null || effort.isEmpty ? null : effort,
      holdClientTools: holdClientTools,
      subagent: subagent,
      mcpConfig: mcpConfig,
    );
  }

  /// The subagent session started for [parentId]'s `run_subagent` call [callId].
  CodeSessionInfo? subagentFor(String parentId, String callId) =>
      state.where((s) => s.parentId == parentId && s.parentCallId == callId).firstOrNull;

  /// Starts a child conversation for [parent]'s `run_subagent` [call]: the parent's
  /// folder, model and effort, [mode], and the task as its first message.
  /// Its model calls are billed to the parent, and the parent's Stop ends
  /// the processes it leaves running (they share the session tag).
  Future<CodeSessionInfo> startSubagent({
    required CodeSessionInfo parent,
    required ActionCall call,
    required AgentMode mode,
  }) async {
    final id = const Uuid().v7();
    final task = SubagentTask.of(call);
    final project = ref.read(codeProjectsProvider).where((p) => p.id == parent.projectId).firstOrNull;
    final projectDir = project?.path ?? parent.workingDir;
    AgentType? role;
    if (task.agent.isNotEmpty && !isDemoPath(projectDir)) {
      try {
        role = (await loadAgentSettings(projectDir)).agents[task.agent];
      } on Object {
        // An unreadable settings file only loses the role's instructions.
      }
    }
    final live = await (await harnessFor(ref, parent.workingDir)).start(
      await specFor(
        sessionId: id,
        sessionTag: parent.id,
        projectDir: projectDir,
        workingDir: parent.workingDir,
        model: parent.model,
        mode: mode,
        effort: parent.effort,
        holdClientTools: false,
        subagent: true,
        initialMessage: modeNote(mode, subagentBrief(task, role: role), subagent: true),
      ),
    );
    ref.read(_liveProvider)[id] = live;
    final info = CodeSessionInfo(
      id: id,
      projectId: parent.projectId,
      title: task.title,
      conversationId: live.id,
      model: parent.model,
      mode: mode,
      workingDir: parent.workingDir,
      createdAt: DateTime.now(),
      branch: parent.branch,
      effort: parent.effort,
      parentId: parent.id,
      parentCallId: call.id,
    );
    state = [...state, info];
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

  /// Removes session [id] and the subagents it started.
  void remove(String id) {
    final gone = {
      id,
      for (final s in state)
        if (s.parentId == id) s.id,
    };
    for (final g in gone) {
      unawaited(ref.read(_liveProvider).remove(g)?.close());
    }
    state = [
      for (final s in state)
        if (!gone.contains(s.id)) s,
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
    this.subagentNeedsInput = false,
  });

  final Transcript transcript;

  /// A subagent this session is waiting on needs the user (an approval).
  final bool subagentNeedsInput;
  final AgentMode mode;

  /// Messages typed while the agent was busy; sent when it stops.
  final List<Outgoing> queued;
  final bool connected;
  final String? error;

  SessionStatus get status => switch (transcript) {
    _ when error != null => SessionStatus.failed,
    Transcript(pending: [_, ...]) => SessionStatus.needsInput,
    final t when t.openQuestion != null || t.openPlan != null => SessionStatus.needsInput,
    // The call (or the turn) waits on subagents; the session is still at work.
    Transcript(openSubagents: [_, ...]) => subagentNeedsInput ? SessionStatus.needsInput : SessionStatus.running,
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
    bool? subagentNeedsInput,
  }) => CodeSessionState(
    transcript: transcript ?? this.transcript,
    mode: mode ?? this.mode,
    queued: queued ?? this.queued,
    connected: connected ?? this.connected,
    error: error ?? this.error,
    subagentNeedsInput: subagentNeedsInput ?? this.subagentNeedsInput,
  );
}

/// How [CodeSessionController.compact] went.
@immutable
final class CompactOutcome {
  const CompactOutcome.compacted(this.summary) : kind = CompactKind.compacted, message = '';
  const CompactOutcome.nothing() : kind = CompactKind.nothing, message = '', summary = '';
  const CompactOutcome.busy() : kind = CompactKind.busy, message = '', summary = '';
  const CompactOutcome.failed(this.message) : kind = CompactKind.failed, summary = '';

  final CompactKind kind;

  /// Why it failed.
  final String message;
  final String summary;
}

enum CompactKind {
  compacted,

  /// The conversation is too short to shorten.
  nothing,

  /// The agent is working or waiting for an answer; try again when it stops.
  busy,
  failed,
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

  final _doom = DoomLoopDetector();

  /// A loop card is waiting for the user: the run is paused and nothing is auto-approved.
  bool _doomOpen = false;

  /// Events before this are history being replayed, which never raise a loop card.
  bool _live = false;

  /// What the current conversation has seen (no deltas), for [compact].
  final _events = <HarnessEvent>[];
  bool _compacting = false;

  /// Subagents this session waits on, by `run_subagent` call id: the child session,
  /// and the subscription that watches it finish.
  final _childOf = <String, String>{};
  final _childSubs = <String, ProviderSubscription<CodeSessionState>>{};
  final _spawning = <String>{};

  /// Calls stopped while their subagent was still starting.
  final _abandoned = <String>{};

  /// Reports not yet handed to the agent, by call id.
  final _reports = <String, SubagentReport>{};
  final _childWaiting = <String>{};
  bool _delivering = false;

  @override
  CodeSessionState build() {
    final info = ref.read(codeSessionsProvider.notifier).byId(sessionId);
    ref.onDispose(() {
      _sub?.cancel();
      _gitTimer?.cancel();
      for (final s in _childSubs.values) {
        s.close();
      }
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
      Timer(const Duration(milliseconds: 1500), () {
        _live = true;
        // Calls still waiting after the history replayed (an app restart).
        if (ref.mounted) _syncSubagents();
      });
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
    if (event is ChatMessage && event.fromUser) {
      _doom.reset();
      _doomOpen = false;
    }
    final looped = event is ActionCall && _doom.add(event) && _live;
    event = _spilled(event);
    if (event is! StreamDelta) _events.add(event);
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
    if (looped) _raiseDoomLoop(_doom.looped!);
    _autoRespond(transcript);
    _syncSubagents();
    _deliver();
    if (!transcript.running &&
        transcript.pending.isEmpty &&
        transcript.openSubagents.isEmpty &&
        state.queued.isNotEmpty) {
      final [next, ...rest] = state.queued;
      state = state.copyWith(queued: rest);
      unawaited(_checkpoint().then((_) => _sendNow(next)));
    }
  }

  /// [event] with a result over the output limits cut to a preview; the whole
  /// text goes to `.everyai/spill/` in the project.
  HarnessEvent _spilled(HarnessEvent event) {
    if (event is! ToolResult) return event;
    final spill = spillOf(event);
    final info = ref.read(codeSessionsProvider.notifier).byId(sessionId);
    if (spill == null || info == null || isDemoPath(info.workingDir)) return event;
    final id = event.toolCallId.isNotEmpty ? event.toolCallId : event.id;
    final path = saveSpill(info.workingDir, Spill.fileName(id), spill.text);
    return path == null ? event : withPreview(event, spillPreview(spill, path));
  }

  /// Pauses the run and asks the user what to do about [call] repeating.
  void _raiseDoomLoop(ActionCall call) {
    _doomOpen = true;
    final what = loopedStep(call);
    final card = ActionCall(
      id: 'doom-${call.id}',
      raw: const {},
      toolName: askUserQuestionTool,
      toolCallId: 'doom-${call.id}',
      action: const {},
    );
    _builder.addLocalQuestion(card, [
      Question(
        header: 'Repeating',
        question: 'The agent has run the same step $doomLoopRepeats times in a row ($what). It is paused. What now?',
        options: const [
          QuestionOption('Let it continue', 'It may be waiting on something slow; keep going as before.'),
          QuestionOption('Stop and change approach', 'Tell it to stop repeating this and try something different.'),
        ],
      ),
    ]);
    state = state.copyWith(transcript: _builder.snapshot);
    unawaited(_session?.pause());
  }

  Future<void> _answerDoomLoop(QuestionItem item, List<QuestionAnswer> answers) async {
    final session = _session;
    if (session == null) return;
    final a = answers.firstOrNull ?? const QuestionAnswer();
    _builder.settleLocal(item.call.id, answers);
    state = state.copyWith(transcript: _builder.snapshot);
    _doom.reset();
    _doomOpen = false;
    if (a.other.trim().isEmpty && !a.selected.contains(1)) {
      await session.resume();
      _autoRespond(state.transcript);
      return;
    }
    final said = a.other.trim().isEmpty ? '' : ' The user says: ${a.other.trim()}';
    final text =
        'You called the same tool with the same input $doomLoopRepeats times in a row without making progress. '
        'Do not repeat it. Take a different approach, or explain what is blocking you.$said';
    final pending = state.transcript.pending;
    if (pending.isNotEmpty) {
      _answered = pending.map((c) => c.id).join(',');
      await session.respond(accept: false, reason: text);
    }
    await session.send(_noted(text));
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
    if (_doomOpen) return;
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
    final subagent = ref.read(codeSessionsProvider.notifier).byId(sessionId)?.isSubagent ?? false;
    return modeNote(state.mode, body, full: told != state.mode, from: told, subagent: subagent);
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
    final t = state.transcript;
    if (t.running || t.pending.isNotEmpty || t.openSubagents.isNotEmpty) {
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
      final reason = plan
          ? '$planRevisionLead see their next message.'
          : held.every(isTaskCall)
          ? subagentInterrupted
          : repliedInChat;
      await session.respond(accept: false, reason: reason);
    }
    await session.send(_noted(out.text), images: out.images);
  }

  /// Interrupts the agent and sends [text] right away.
  Future<void> steer(String text, {List<Attachment> files = const []}) async {
    final out = await _outgoing(text, files);
    if (out == null) return;
    await _session?.interrupt();
    await _stopSubagents();
    await _checkpoint();
    await _sendNow(out);
  }

  /// Shortens the agent's context: old tool output is cleared, the older part
  /// of the conversation is summarized by [compactionModel] (keeping what
  /// [focus] asks for), and the session moves to a new conversation that
  /// starts with the summary and the newest turns word for word. With
  /// [resume] the agent carries on at once; otherwise it waits for the next
  /// message. The transcript so far stays on screen.
  ///
  /// [summarizer] replaces the gateway call (tests).
  Future<CompactOutcome> compact({String focus = '', bool resume = false, Summarizer? summarizer}) async {
    final info = ref.read(codeSessionsProvider.notifier).byId(sessionId);
    final old = _session;
    if (info == null || old == null) return const CompactOutcome.failed('The session is not connected.');
    if (isDemoPath(info.workingDir)) return const CompactOutcome.failed("The demo session can't be compacted.");
    final t = state.transcript;
    if (_compacting || t.running || t.pending.isNotEmpty || t.held.isNotEmpty) return const CompactOutcome.busy();
    final plan = planCompaction(_events);
    if (plan == null) return const CompactOutcome.nothing();
    _compacting = true;
    try {
      final summarize =
          summarizer ??
          gatewaySummarizer(baseUrl: gatewayBaseUrl(ref), apiKey: await gatewayKey(ref), sessionTag: info.id);
      final summary = cleanSummary(await summarize(summaryRequest(plan, focus: focus)));
      if (summary == null) return const CompactOutcome.failed("The summary didn't come back in the expected form.");
      final message = continuationMessage(summary: summary, recent: renderTail(plan), resume: resume);
      final project = ref.read(codeProjectsProvider).where((p) => p.id == info.projectId).firstOrNull;
      final sessions = ref.read(codeSessionsProvider.notifier);
      final spec = await sessions.specFor(
        sessionId: info.id,
        projectDir: project?.path ?? info.workingDir,
        workingDir: info.workingDir,
        model: info.model,
        mode: state.mode,
        effort: info.effort,
        holdClientTools: info.holdClientTools,
        initialMessage: modeNote(state.mode, message),
        runInitial: resume,
      );
      final live = await (await harnessFor(ref, info.workingDir)).start(spec);
      if (!ref.mounted) {
        unawaited(live.close());
        return const CompactOutcome.failed('The session was closed.');
      }
      // Swap conversations; the transcript builder keeps what's on screen.
      await _sub?.cancel();
      unawaited(old.close());
      ref.read(_liveProvider)[sessionId] = live;
      _session = live;
      _events.clear();
      _answered = '';
      _doom.reset();
      sessions.update(
        info.copyWith(conversationId: live.id, compactedFrom: [...info.compactedFrom, info.conversationId]),
      );
      // Nested instruction files were in the old context; they go out again when touched.
      await _openContext(info);
      _sub = live.events.listen(_onEvent);
      return CompactOutcome.compacted(summary);
    } on Object catch (e) {
      return CompactOutcome.failed('$e');
    } finally {
      _compacting = false;
    }
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
    _doomOpen = false;
    state = state.copyWith(queued: const []);
    await _stopSubagents();
    final pending = state.transcript.pending;
    final info = ref.read(codeSessionsProvider.notifier).byId(sessionId);
    // A subagent tells the session that started it, which carries on without it.
    if (info?.parentId case final parent?) {
      if (ref.exists(codeSessionProvider(parent))) {
        ref.read(codeSessionProvider(parent).notifier).subagentStopped(sessionId, stoppedReport(state.transcript));
      }
    }
    if (pending.isNotEmpty || state.transcript.held.any(isTaskCall)) {
      _answered = [...pending, ...state.transcript.held].map((c) => c.id).join(',');
      await _session?.respond(accept: false, reason: denialMessage(DenialKind.cancelled));
    }
    // Ctrl-C reaches only the terminal's foreground command; background jobs,
    // servers and commands left running after a timeout are ended here. A
    // subagent shares its parent's tag, so only the parent's Stop does this.
    await Future.wait([
      ?_session?.interrupt(),
      if (info != null && !isDemoPath(info.workingDir) && !info.isSubagent)
        killSessionProcesses(tag: info.id, workingDir: info.workingDir, ownsDir: info.worktree != null),
    ]);
  }

  /// Starts a child conversation for each new `run_subagent` call, or picks up the
  /// one already running for it (after a restart). Replayed history never
  /// starts one: only calls still open once the session is live.
  void _syncSubagents() {
    if (!_live || !ref.mounted) return;
    final sessions = ref.read(codeSessionsProvider.notifier);
    final info = sessions.byId(sessionId);
    if (info == null || info.isSubagent) return;
    final t = state.transcript;
    for (final item in t.openSubagents) {
      final id = item.step.call.id;
      if (_childOf.containsKey(id) || _reports.containsKey(id) || _spawning.contains(id)) continue;
      // A held call runs its subagent while the server waits for the result.
      if (_holds && !t.held.any((c) => c.id == id)) continue;
      if (sessions.subagentFor(sessionId, id) case final child?) {
        _watch(id, child.id);
      } else if (_childOf.length + _spawning.length >= maxConcurrentSubagents) {
        _ready(
          id,
          const SubagentReport(
            SubagentStatus.notStarted,
            'Not started: at most $maxConcurrentSubagents subagents run at once. Start it again once the others '
            'have reported.',
          ),
        );
      } else {
        unawaited(_spawn(id, item.step.call, info));
      }
    }
  }

  Future<void> _spawn(String callId, ActionCall call, CodeSessionInfo parent) async {
    _spawning.add(callId);
    try {
      final child = await ref
          .read(codeSessionsProvider.notifier)
          .startSubagent(parent: parent, call: call, mode: subagentMode(state.mode));
      if (!ref.mounted || _abandoned.remove(callId)) {
        unawaited(ref.read(_liveProvider)[child.id]?.interrupt());
        return;
      }
      _spawning.remove(callId);
      _watch(callId, child.id);
    } on Object catch (e) {
      _spawning.remove(callId);
      if (ref.mounted && !_abandoned.remove(callId)) {
        _ready(callId, SubagentReport(SubagentStatus.notStarted, "The subagent couldn't start: $e"));
      }
    }
  }

  void _watch(String callId, String childId) {
    _childOf[callId] = childId;
    final sub = ref.listen(codeSessionProvider(childId), (_, next) => _onSubagent(callId, next), fireImmediately: true);
    // It may have finished already (fireImmediately).
    if (_childOf.containsKey(callId)) {
      _childSubs[callId] = sub;
    } else {
      sub.close();
    }
  }

  void _onSubagent(String callId, CodeSessionState child) {
    if (!_childOf.containsKey(callId)) return;
    final outcome = subagentOutcome(child.transcript, error: child.error);
    if (outcome != null) return _ready(callId, outcome);
    final waiting = child.status == SessionStatus.needsInput;
    if (waiting ? _childWaiting.add(callId) : _childWaiting.remove(callId)) {
      state = state.copyWith(subagentNeedsInput: _childWaiting.isNotEmpty);
    }
  }

  void _ready(String callId, SubagentReport report) {
    _reports[callId] = report;
    _childOf.remove(callId);
    _childSubs.remove(callId)?.close();
    _childWaiting.remove(callId);
    state = state.copyWith(subagentNeedsInput: _childWaiting.isNotEmpty);
    _deliver();
  }

  /// A subagent of this session was stopped by the user: the agent gets what
  /// it had said so far and carries on.
  void subagentStopped(String childId, SubagentReport report) {
    final callId = _childOf.entries.where((e) => e.value == childId).firstOrNull?.key;
    if (callId != null) _ready(callId, report);
  }

  /// Gives the agent its subagents' reports once every subagent it waits on
  /// has one: as the held calls' result, else as one message when it's idle.
  void _deliver() {
    final session = _session;
    if (_reports.isEmpty || _delivering || session == null) return;
    final t = state.transcript;
    final open = [for (final s in t.openSubagents) s.step.call.id];
    // Calls closed some other way (a reply in chat) no longer want a report.
    _reports.removeWhere((id, _) => !open.contains(id));
    if (_reports.isEmpty || !open.every(_reports.containsKey)) return;
    final reports = {for (final id in open) id: _reports[id]!};
    final Future<void> sent;
    if (_holds) {
      if (!t.held.any((c) => reports.containsKey(c.id))) return;
      sent = _replyInCall(session, subagentReason(reports));
    } else {
      if (t.running || t.pending.isNotEmpty) return;
      sent = session.send(_noted(subagentMessage(reports)));
    }
    _delivering = true;
    unawaited(
      sent
          .then((_) => reports.keys.forEach(_reports.remove), onError: (Object _) {})
          .whenComplete(() => _delivering = false),
    );
  }

  /// Stops every subagent this session waits on. Held calls are answered by
  /// the caller; the cards of calls that ended the turn close here.
  Future<void> _stopSubagents() async {
    final open = [for (final s in state.transcript.openSubagents) s.step.call.id];
    if (open.isEmpty) return;
    final children = [..._childOf.values];
    _abandoned.addAll(_spawning);
    for (final s in _childSubs.values) {
      s.close();
    }
    _childSubs.clear();
    _childOf.clear();
    _reports.clear();
    _childWaiting.clear();
    state = state.copyWith(subagentNeedsInput: false);
    await Future.wait([for (final c in children) ref.read(codeSessionProvider(c).notifier).stop()]);
    if (!_holds) {
      _builder.settleSubagents(open, const SubagentReport(SubagentStatus.stopped, 'Stopped by the user.'));
      state = state.copyWith(transcript: _builder.snapshot);
    }
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
    if (item.call.id.startsWith('doom-')) return _answerDoomLoop(item, answers);
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
