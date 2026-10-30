import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/providers.dart';
import '../../agents/agents_providers.dart' show childSetup, codeAgentsFor;
import '../../billing/billing_providers.dart' show BillingSummary;
import '../../models/domain/model_catalog.dart';
import '../../models/models_providers.dart';
import '../../usage/usage_totals.dart';
import '../code_providers.dart';
import '../domain/agent_mode.dart';
import '../domain/code_session.dart';
import '../domain/subagents.dart';
import '../domain/transcript.dart';
import '../git/git_service.dart';
import '../harness/events.dart';
import '../harness/session_processes.dart';
import 'data/ultra_store.dart';
import 'domain/ultra_engine.dart';
import 'domain/ultra_journal.dart';
import 'domain/ultra_plan.dart';
import 'domain/ultra_prompts.dart';

/// Where an Ultra run is, as the app sees it.
enum UltraStage {
  /// The orchestrator is reading the project and writing its plan.
  planning,

  /// The engine runs the plan.
  running,

  /// The orchestrator writes the answer from the results.
  synthesizing,
  done,
  failed,
}

@immutable
final class UltraRunView {
  const UltraRunView({
    required this.runId,
    required this.sessionId,
    required this.orchestratorId,
    required this.goal,
    this.stage = UltraStage.planning,
    this.journal,
    this.answer = '',
    this.error = '',
  });

  final String runId;

  /// The Code session it was started from.
  final String sessionId;
  final String orchestratorId;
  final String goal;
  final UltraStage stage;

  /// The engine's journal once the plan is accepted (mutable; read it as a
  /// snapshot when the view changes).
  final UltraJournal? journal;

  /// The orchestrator's final message.
  final String answer;
  final String error;

  UltraRunView copyWith({UltraStage? stage, UltraJournal? journal, String? answer, String? error}) => UltraRunView(
    runId: runId,
    sessionId: sessionId,
    orchestratorId: orchestratorId,
    goal: goal,
    stage: stage ?? this.stage,
    journal: journal ?? this.journal,
    answer: answer ?? this.answer,
    error: error ?? this.error,
  );
}

/// The run could not start; [message] is for the user.
final class UltraError implements Exception {
  const UltraError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// `GET /v1/billing`: the plan and what is left to spend.
final class BillingWallet implements UltraWallet {
  BillingWallet(this.ref);
  final Ref ref;

  @override
  Future<WalletReading> read() async {
    final json = await ref
        .read(apiClientProvider)
        .getJson('v1/billing', authenticated: !ref.read(appConfigProvider).devSkipAuth);
    final b = BillingSummary.fromJson(json);
    return WalletReading(planId: b.plan.id, availableMicros: b.walletMicros + b.quotaLeftMicros);
  }
}

/// Ultra runs by id.
final ultraRunsProvider = NotifierProvider<UltraRuns, Map<String, UltraRunView>>(UltraRuns.new);

final class UltraRuns extends Notifier<Map<String, UltraRunView>> {
  final _engines = <String, UltraEngine>{};
  final _subs = <String, ProviderSubscription<CodeSessionState>>{};

  /// The orchestrator's user turns when its results were sent: its answer
  /// is the turn after.
  final _reportTurns = <String, int>{};
  final _sawRunning = <String>{};

  /// `ultra_plan` calls already taken, by run.
  final _handled = <String, Set<String>>{};

  /// Plans sent back for fixes, by run.
  final _rejections = <String, int>{};

  /// When each run started planning, and when its synthesis started.
  final _plannedFrom = <String, DateTime>{};
  final _synthesisFrom = <String, DateTime>{};

  /// Checks the caps while the orchestrator plans or writes the answer
  /// (the engine checks them in between).
  final _guards = <String, Timer>{};

  @override
  Map<String, UltraRunView> build() {
    ref.onDispose(() {
      for (final e in _engines.values) {
        e.stop();
      }
      for (final g in _guards.values) {
        g.cancel();
      }
      for (final s in _subs.values) {
        s.close();
      }
    });
    return const {};
  }

  void _put(UltraRunView v) => state = {...state, v.runId: v};

  /// Starts an Ultra run on [goal] from session [sessionId]: the Max plan
  /// and the wallet are checked, then an orchestrator child (Opus) plans.
  /// Returns the run id.
  Future<String> start({
    required String sessionId,
    required String goal,
    UltraLimits limits = const UltraLimits(),
  }) async {
    final sessions = ref.read(codeSessionsProvider.notifier);
    final parent = sessions.byId(sessionId);
    if (parent == null) throw const UltraError('The session is gone.');
    if (isDemoPath(parent.workingDir)) throw const UltraError('Ultra runs need a real project.');
    final WalletReading wallet;
    try {
      wallet = await BillingWallet(ref).read();
    } on Object catch (e) {
      throw UltraError("Couldn't check the plan: $e");
    }
    if (!ultraAllowedOn(wallet.planId)) throw const UltraError('Ultra runs are part of the Max plan.');
    if (wallet.availableMicros <= 0) throw const UltraError('There is no credit left for an Ultra run.');
    final runId = const Uuid().v7();
    final orchestrator = await sessions.startChild(
      parent: parent,
      title: 'Ultra: ${_title(goal)}',
      brief: ultraOrchestratorBrief(goal),
      // It only reads; the steps do the work.
      mode: AgentMode.plan,
      callId: 'ultra-$runId',
      model: ultraOrchestratorModel,
      effort: 'high',
      rolePrompt: ultraOrchestratorRules(limits),
      clientTools: const [ultraPlanSpec],
      ownTag: true,
    );
    _put(UltraRunView(runId: runId, sessionId: sessionId, orchestratorId: orchestrator.id, goal: goal));
    _limits[runId] = limits;
    _plannedFrom[runId] = DateTime.now();
    _watch(runId, orchestrator.id);
    _guard(runId);
    return runId;
  }

  /// What session [id] has cost so far, from the ledger; null when it can't be read.
  Future<int?> _sessionCost(String id) async {
    try {
      final json = await ref
          .read(apiClientProvider)
          .getJson('v1/usage/session/$id', authenticated: !ref.read(appConfigProvider).devSkipAuth);
      return UsageTotals.fromJson(json).chargedMicros;
    } on Object {
      return null;
    }
  }

  /// Every [ultraGuardEvery], while the orchestrator plans or synthesizes:
  /// stops the run once the orchestrator's spend (with the steps') or the
  /// time passes the run's caps. Synthesis gets a little room past them
  /// ([ultraSynthesisGrace]), so a capped run still gets its write-up.
  void _guard(String runId) {
    _guards.remove(runId)?.cancel();
    _guards[runId] = Timer.periodic(ultraGuardEvery, (_) async {
      final v = state[runId];
      if (v == null || (v.stage != UltraStage.planning && v.stage != UltraStage.synthesizing)) {
        _guards.remove(runId)?.cancel();
        return;
      }
      final cost = await _sessionCost(v.orchestratorId);
      final now = state[runId];
      if (!ref.mounted || now == null || now.stage != v.stage) return;
      final limits = _limits[runId] ?? now.journal?.limits ?? const UltraLimits();
      final over = ultraGuardOver(
        stage: now.stage,
        limits: limits,
        journal: now.journal,
        orchestratorMicros: cost,
        planningFor: DateTime.now().difference(_plannedFrom[runId] ?? DateTime.now()),
        synthesizingFor: DateTime.now().difference(_synthesisFrom[runId] ?? DateTime.now()),
      );
      if (over == null) return;
      _guards.remove(runId)?.cancel();
      _subs.remove(runId)?.close();
      unawaited(ref.read(codeSessionProvider(now.orchestratorId).notifier).stop());
      _put(now.copyWith(stage: UltraStage.failed, error: over));
    });
  }

  final _limits = <String, UltraLimits>{};

  /// Picks up a run from its journal (after a restart, or a stop): finished
  /// steps stay, the rest run, then the orchestrator gets the results.
  Future<void> resume(String runId) async {
    final store = ultraJournalStore(await GitService.dataDir());
    final journal = await store.load(runId);
    if (journal == null) throw const UltraError('The run has no journal.');
    if (ref.read(codeSessionsProvider.notifier).byId(journal.sessionId) == null) {
      throw const UltraError('The session the run belongs to is gone.');
    }
    if (_engines.containsKey(runId)) return;
    journal
      ..status = UltraRunStatus.running
      ..note = '';
    _put(
      UltraRunView(
        runId: runId,
        sessionId: journal.sessionId,
        orchestratorId: journal.orchestratorId,
        goal: journal.plan.goal,
        stage: UltraStage.running,
        journal: journal,
      ),
    );
    _handled.putIfAbsent(runId, () => {}).add(journal.planCallId);
    _limits[runId] = journal.limits;
    _watch(runId, journal.orchestratorId);
    unawaited(_run(runId, journal));
  }

  /// Stops the run's agents (the orchestrator then writes up what it has).
  void stop(String runId) {
    final engine = _engines[runId];
    if (engine != null) return engine.stop();
    final v = state[runId];
    if (v == null || v.stage == UltraStage.done || v.stage == UltraStage.failed) return;
    unawaited(ref.read(codeSessionProvider(v.orchestratorId).notifier).stop());
    _put(v.copyWith(stage: UltraStage.failed, error: 'Stopped.'));
    _subs.remove(runId)?.close();
    _guards.remove(runId)?.cancel();
  }

  void _watch(String runId, String orchestratorId) {
    _subs[runId]?.close();
    _subs[runId] = ref.listen(
      codeSessionProvider(orchestratorId),
      (_, s) => _onOrchestrator(runId, s),
      fireImmediately: true,
    );
  }

  void _onOrchestrator(String runId, CodeSessionState s) {
    final v = state[runId];
    if (v == null) return;
    final t = s.transcript;
    switch (v.stage) {
      case UltraStage.planning:
        final handled = _handled.putIfAbsent(runId, () => {});
        final call = ultraPlanCalls(t).where((c) => !handled.contains(c.id)).firstOrNull;
        if (call != null) {
          handled.add(call.id);
          _takePlan(runId, call);
          return;
        }
        // It answered without a plan (a question too small to fan out).
        if (subagentOutcome(t, error: s.error) case final outcome?) _settle(runId, outcome);
      case UltraStage.synthesizing:
        final turns = t.items.whereType<UserTurn>().length;
        if (turns <= (_reportTurns[runId] ?? 0)) return;
        if (t.running) _sawRunning.add(runId);
        if (!_sawRunning.contains(runId)) return;
        if (subagentOutcome(t, error: s.error) case final outcome?) _settle(runId, outcome);
      case UltraStage.running || UltraStage.done || UltraStage.failed:
        return;
    }
  }

  void _settle(String runId, SubagentReport outcome) {
    final v = state[runId]!;
    _subs.remove(runId)?.close();
    _guards.remove(runId)?.cancel();
    _put(
      outcome.status == SubagentStatus.completed
          ? v.copyWith(stage: UltraStage.done, answer: outcome.text)
          : v.copyWith(stage: UltraStage.failed, error: outcome.text),
    );
  }

  void _takePlan(String runId, ActionCall call) {
    final v = state[runId]!;
    final parent = ref.read(codeSessionsProvider.notifier).byId(v.sessionId);
    if (parent == null) return _put(v.copyWith(stage: UltraStage.failed, error: 'The session is gone.'));
    final limits = _limits[runId] ?? const UltraLimits();
    final parsed = parseUltraPlan(call.action, limits: limits, allowWrites: _allowWrites(parent));
    final orchestrator = ref.read(codeSessionProvider(v.orchestratorId).notifier);
    if (parsed.plan == null) {
      final tries = _rejections[runId] = (_rejections[runId] ?? 0) + 1;
      if (tries > ultraMaxPlanRejections) {
        _subs.remove(runId)?.close();
        _guards.remove(runId)?.cancel();
        unawaited(orchestrator.stop());
        return _put(
          v.copyWith(
            stage: UltraStage.failed,
            error: 'The orchestrator did not produce a plan that could run after $ultraMaxPlanRejections tries.',
          ),
        );
      }
      // Sent once its turn ends (it ends the turn after the call).
      unawaited(orchestrator.send(ultraPlanRejected(parsed.errors)));
      return;
    }
    final journal = UltraJournal(
      runId: runId,
      sessionId: v.sessionId,
      orchestratorId: v.orchestratorId,
      planCallId: call.id,
      plan: parsed.plan!,
      limits: limits,
      createdAt: DateTime.now(),
      // Planning counts toward the run's time.
      elapsed: DateTime.now().difference(_plannedFrom[runId] ?? DateTime.now()),
    );
    _put(v.copyWith(stage: UltraStage.running, journal: journal));
    unawaited(_run(runId, journal));
  }

  static bool _allowWrites(CodeSessionInfo parent) => parent.mode != AgentMode.plan;

  Future<void> _run(String runId, UltraJournal journal) async {
    final sessions = ref.read(codeSessionsProvider.notifier);
    final parent = sessions.byId(journal.sessionId);
    if (parent == null) return;
    try {
      final data = await GitService.dataDir();
      final base = parent.worktree;
      // Step worktrees start from the session's current state.
      if (base != null) await ultraSaveBase(base);
      final engine = UltraEngine(
        journal: journal,
        runner: SessionUltraRunner(ref, parentId: parent.id, runId: runId),
        wallet: BillingWallet(ref),
        workspace: ultraWorkspace(base: base, dataDir: data),
        store: ultraJournalStore(data),
        allowWrites: _allowWrites(parent),
        orchestratorCost: () => _sessionCost(journal.orchestratorId),
        onChange: (j) {
          if (!ref.mounted) return;
          if (state[runId] case final v?) _put(v.copyWith(journal: j));
        },
      );
      _engines[runId] = engine;
      final done = await engine.run();
      _engines.remove(runId);
      if (!ref.mounted) return;
      final v = state[runId]!;
      final orchestrator = ref.read(codeSessionProvider(v.orchestratorId));
      _reportTurns[runId] = orchestrator.transcript.items.whereType<UserTurn>().length;
      _sawRunning.remove(runId);
      _synthesisFrom[runId] = DateTime.now();
      _put(v.copyWith(stage: UltraStage.synthesizing, journal: done));
      _guard(runId);
      await ref.read(codeSessionProvider(v.orchestratorId).notifier).send(ultraReport(done));
    } on Object catch (e) {
      _engines.remove(runId);
      if (!ref.mounted) return;
      if (state[runId] case final v?) _put(v.copyWith(stage: UltraStage.failed, error: 'The run failed: $e'));
    }
  }

  static String _title(String goal) {
    final line = goal.trim().split('\n').first;
    return line.length <= 48 ? line : '${line.substring(0, 47)}…';
  }
}

/// Plans sent back to the orchestrator before the run gives up.
const ultraMaxPlanRejections = 3;

/// How often the caps are checked while the orchestrator works.
const ultraGuardEvery = Duration(seconds: 15);

/// How far past its caps a run's synthesis may go: a share of the budget and some time.
const ultraSynthesisGrace = (budgetShare: 0.1, time: Duration(minutes: 10));

/// Why the orchestrator has to stop in [stage], or null while it is within
/// the caps. Planning counts the orchestrator's spend ([orchestratorMicros],
/// null when unread) and time; synthesis adds the steps' spend and the
/// journal's time, with [ultraSynthesisGrace] of room.
String? ultraGuardOver({
  required UltraStage stage,
  required UltraLimits limits,
  required UltraJournal? journal,
  required int? orchestratorMicros,
  required Duration planningFor,
  required Duration synthesizingFor,
}) {
  String money(int micros) => '\$${(micros / 1e6).toStringAsFixed(2)}';
  switch (stage) {
    case UltraStage.planning:
      if ((orchestratorMicros ?? 0) >= limits.budgetMicros) {
        return "Planning reached the run's ${money(limits.budgetMicros)} cap.";
      }
      if (planningFor >= limits.wallTime) {
        return "Planning reached the run's ${limits.wallTime.inMinutes}-minute limit.";
      }
    case UltraStage.synthesizing:
      final j = journal;
      if (j == null) return null;
      final budget = j.budgetMicros > 0 ? j.budgetMicros : limits.budgetMicros;
      final steps = j.spentMicros - j.orchestratorMicros;
      final spent = steps + math.max(j.orchestratorMicros, orchestratorMicros ?? 0);
      if (spent >= budget + (budget * ultraSynthesisGrace.budgetShare).round()) {
        return "The write-up went past the run's ${money(budget)} cap.";
      }
      if (j.elapsed + synthesizingFor >= limits.wallTime + ultraSynthesisGrace.time) {
        return "The write-up went past the run's ${limits.wallTime.inMinutes}-minute limit.";
      }
    case UltraStage.running || UltraStage.done || UltraStage.failed:
      return null;
  }
  return null;
}

/// The `ultra_plan` calls in an orchestrator's transcript, oldest first.
List<ActionCall> ultraPlanCalls(Transcript t) => [
  for (final item in t.items)
    ...switch (item) {
      StepItem(:final step) => [step.call],
      ExploreGroup(:final steps) => [for (final s in steps) s.call],
      _ => const <ActionCall>[],
    }.where((c) => c.toolName == ultraPlanTool),
];

/// The read-only/full-auto split for Ultra children: steps that write and
/// checks of their worktrees run unattended there; everything else reads.
AgentMode ultraChildMode(UltraChildRequest r) =>
    r.writes || (r.role == ChildRole.verify && r.workingDir != null) ? AgentMode.fullAuto : AgentMode.plan;

/// Runs each Ultra step as a child session of the run's Code session,
/// billed under its own id so the engine can read what each one cost.
final class SessionUltraRunner implements UltraChildRunner {
  SessionUltraRunner(this.ref, {required this.parentId, required this.runId});

  final Ref ref;
  final String parentId;
  final String runId;
  int _n = 0;

  @override
  Future<UltraChild> start(UltraChildRequest r) async {
    final sessions = ref.read(codeSessionsProvider.notifier);
    final parent = sessions.byId(parentId);
    if (parent == null) throw const UltraError('The session is gone.');
    final agent = r.agent == null
        ? null
        : (await codeAgentsFor(ref, parent.projectId)).where((a) => a.name == r.agent).firstOrNull;
    final setup = childSetup(
      agent,
      parentMode: ultraChildMode(r),
      parentModel: r.model ?? r.fallbackModel,
      parentEffort: r.effort,
      modelKnown: (m) {
        final catalog = ref.read(modelCatalogProvider);
        return catalog.length == 0 || catalog[ModelId(m)] != null;
      },
    );
    final info = await sessions.startChild(
      parent: parent,
      title: r.title,
      brief: r.brief,
      mode: setup.mode,
      callId: 'ultra-$runId-${r.key}-${++_n}',
      // The plan's own model choice beats the agent file's.
      model: r.model ?? setup.model,
      effort: r.effort ?? setup.effort ?? '',
      tools: setup.tools,
      rolePrompt: setup.rolePrompt,
      workingDir: r.workingDir,
      ownTag: true,
    );
    return _SessionChild(ref, info.id);
  }

  @override
  Future<int?> abandon(String childId) async {
    if (ref.read(codeSessionsProvider.notifier).byId(childId) != null) {
      await ref.read(codeSessionProvider(childId).notifier).stop();
    }
    try {
      final json = await ref
          .read(apiClientProvider)
          .getJson('v1/usage/session/$childId', authenticated: !ref.read(appConfigProvider).devSkipAuth);
      return UsageTotals.fromJson(json).chargedMicros;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> release(String childId) async {
    final sessions = ref.read(codeSessionsProvider.notifier);
    final info = sessions.byId(childId);
    if (info == null || !killsOwnProcesses(info)) return;
    await killSessionProcesses(
      tag: info.id,
      workingDir: info.workingDir,
      ownsDir: ownsWorkingDir(info, parent: sessions.byId(info.parentId ?? '')),
    );
  }
}

/// A child session seen as an [UltraChild]: a turn is over when the
/// transcript says finished or failed, and its cost comes from the ledger.
final class _SessionChild implements UltraChild {
  _SessionChild(this.ref, this.id) {
    _sub = ref.listen(codeSessionProvider(id), (_, s) => _on(s), fireImmediately: true);
    _poll = Timer.periodic(const Duration(seconds: 15), (_) => unawaited(_readCost()));
  }

  final Ref ref;
  @override
  final String id;
  late final ProviderSubscription<CodeSessionState> _sub;
  late Timer _poll;
  bool _settling = false;
  var _turn = Completer<ChildResult>();
  int _minTurns = 0;
  bool _awaitRun = false;

  @override
  int costMicros = 0;

  @override
  Future<ChildResult> get result => _turn.future;

  void _on(CodeSessionState s) {
    if (_turn.isCompleted || _settling) return;
    final t = s.transcript;
    if (_awaitRun) {
      if (!t.running) return;
      _awaitRun = false;
    }
    if (t.items.whereType<UserTurn>().length <= _minTurns) return;
    final outcome = subagentOutcome(t, error: s.error);
    if (outcome == null) return;
    _complete(switch (outcome.status) {
      SubagentStatus.completed => ChildResult(ChildEnd.completed, outcome.text),
      SubagentStatus.stopped => ChildResult(ChildEnd.stopped, outcome.text),
      _ => ChildResult(ChildEnd.failed, outcome.text),
    });
  }

  /// Settles the turn once the ledger has caught up with its last call.
  Future<void> _complete(ChildResult r) async {
    final turn = _turn;
    _settling = true;
    _poll.cancel();
    try {
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      await _readCost();
    } finally {
      _settling = false;
      if (!turn.isCompleted) turn.complete(r);
    }
  }

  Future<void> _readCost() async {
    try {
      final json = await ref
          .read(apiClientProvider)
          .getJson('v1/usage/session/$id', authenticated: !ref.read(appConfigProvider).devSkipAuth);
      costMicros = UsageTotals.fromJson(json).chargedMicros;
    } on Object {
      // The last reading stands.
    }
  }

  @override
  Future<ChildResult> followUp(String message) async {
    _turn = Completer<ChildResult>();
    _minTurns = ref.read(codeSessionProvider(id)).transcript.items.whereType<UserTurn>().length;
    _awaitRun = true;
    _poll = Timer.periodic(const Duration(seconds: 15), (_) => unawaited(_readCost()));
    await ref.read(codeSessionProvider(id).notifier).send(message);
    return _turn.future;
  }

  @override
  Future<void> stop() async {
    await ref.read(codeSessionProvider(id).notifier).stop();
    final s = ref.read(codeSessionProvider(id));
    await _complete(ChildResult(ChildEnd.stopped, stoppedReport(s.transcript).text));
    _sub.close();
  }
}
