import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../billing/billing_providers.dart' show billingProvider;
import '../code_providers.dart';
import '../git/git_service.dart';
import 'data/ultra_store.dart';
import 'domain/ultra_journal.dart';
import 'domain/ultra_plan.dart';
import 'ultra_providers.dart';

/// The caps a plan allows an Ultra run, or null when the plan has no Ultra.
/// Max gets the user's defaults as its ceiling.
UltraLimits? ultraPlanLimits(String planId) => ultraAllowedOn(planId) ? const UltraLimits() : null;

/// What the caps popover steps through, each list capped by the plan.
abstract final class UltraCapSteps {
  static const concurrent = [1, 2, 4, 6, 8, 12, 16];
  static const agents = [5, 10, 20, 30, 50, 75, 100, 150];
  static const dollars = [1, 2, 5, 10, 15, 20, 25];
  static const wallMinutes = [15, 30, 45, 60, 90, 120];

  /// The next value from [steps] after [current] in direction [dir] (±1),
  /// kept within `1..max` (max is always a stop).
  static int next(List<int> steps, int current, int dir, int max) {
    final stops = {...steps.where((s) => s <= max), max}.toList()..sort();
    if (dir > 0) return stops.firstWhere((s) => s > current, orElse: () => stops.last);
    return stops.lastWhere((s) => s < current, orElse: () => stops.first);
  }
}

/// [l] kept within [max] (and above sensible floors).
UltraLimits clampUltraLimits(UltraLimits l, UltraLimits max) => UltraLimits(
  maxConcurrent: l.maxConcurrent.clamp(1, max.maxConcurrent),
  maxAgents: l.maxAgents.clamp(1, max.maxAgents),
  budgetMicros: l.budgetMicros.clamp(100000, max.budgetMicros),
  wallTime: Duration(minutes: l.wallTime.inMinutes.clamp(5, max.wallTime.inMinutes)),
  verifyRetries: l.verifyRetries.clamp(0, max.verifyRetries),
  maxPhases: max.maxPhases,
  maxStepsPerPhase: max.maxStepsPerPhase,
  maxItems: max.maxItems,
);

/// The caps the signed-in plan allows Ultra runs; null when it has none.
/// Reads `/v1/billing` (the engine checks the plan again before it starts).
final ultraAccessProvider = FutureProvider.autoDispose<UltraLimits?>((ref) async {
  final billing = await ref.watch(billingProvider.future);
  return ultraPlanLimits(billing.plan.id);
});

/// A session's Ultra toggle: whether the next message starts a run, and the
/// caps it runs under.
@immutable
final class UltraToggle {
  const UltraToggle({this.armed = false, this.limits = const UltraLimits()});

  final bool armed;
  final UltraLimits limits;

  UltraToggle copyWith({bool? armed, UltraLimits? limits}) =>
      UltraToggle(armed: armed ?? this.armed, limits: limits ?? this.limits);
}

/// The Ultra toggle by session id (kept for the app's lifetime).
final ultraToggleProvider = NotifierProvider.family<UltraToggleController, UltraToggle, String>(
  UltraToggleController.new,
);

final class UltraToggleController extends Notifier<UltraToggle> {
  UltraToggleController(this.sessionId);
  final String sessionId;

  @override
  UltraToggle build() => const UltraToggle();

  void setArmed(bool on) => state = state.copyWith(armed: on);

  void setLimits(UltraLimits limits, {UltraLimits max = const UltraLimits()}) =>
      state = state.copyWith(limits: clampUltraLimits(limits, max));

  void reset() => state = state.copyWith(limits: const UltraLimits());
}

/// One Ultra run as the progress tree shows it: live from [ultraRunsProvider],
/// or read back from its journal after a restart.
@immutable
final class UltraRunEntry {
  const UltraRunEntry({
    required this.runId,
    required this.sessionId,
    required this.goal,
    required this.stage,
    required this.live,
    this.orchestratorId = '',
    this.journal,
    this.answer = '',
    this.error = '',
  });

  factory UltraRunEntry.fromView(UltraRunView v) => UltraRunEntry(
    runId: v.runId,
    sessionId: v.sessionId,
    goal: v.goal,
    stage: v.stage,
    live: true,
    orchestratorId: v.orchestratorId,
    journal: v.journal,
    answer: v.answer,
    error: v.error,
  );

  /// A run this app run didn't start: its stage is what the journal says.
  factory UltraRunEntry.fromJournal(UltraJournal j) => UltraRunEntry(
    runId: j.runId,
    sessionId: j.sessionId,
    goal: j.plan.goal,
    stage: switch (j.status) {
      UltraRunStatus.done || UltraRunStatus.capped => UltraStage.done,
      _ => UltraStage.failed,
    },
    live: false,
    orchestratorId: j.orchestratorId,
    journal: j,
    error: switch (j.status) {
      UltraRunStatus.running => 'The app closed while this run was going.',
      UltraRunStatus.stopped => 'Stopped.',
      _ => j.note,
    },
  );

  final String runId;
  final String sessionId;
  final String goal;
  final UltraStage stage;

  /// Started (or resumed) in this app run.
  final bool live;
  final String orchestratorId;
  final UltraJournal? journal;
  final String answer;
  final String error;

  /// The orchestrator or its agents are working.
  bool get active =>
      live && (stage == UltraStage.planning || stage == UltraStage.running || stage == UltraStage.synthesizing);

  /// It can carry on from its journal: cut off by a quit, or stopped.
  bool get resumable =>
      !active &&
      journal != null &&
      (journal!.status == UltraRunStatus.stopped || journal!.status == UltraRunStatus.running);
}

/// Journals on disk for [sessionId]'s runs, oldest first.
final ultraSavedRunsProvider = FutureProvider.family<List<UltraJournal>, String>((ref, sessionId) async {
  final data = await GitService.dataDir();
  final store = ultraJournalStore(data);
  final out = <UltraJournal>[];
  for (final id in await ultraRunIds(data)) {
    final j = await store.load(id);
    if (j != null && j.sessionId == sessionId) out.add(j);
  }
  return out..sort((a, b) => a.createdAt.compareTo(b.createdAt));
});

/// Every Ultra run of a session, oldest first: the live ones, plus journals
/// from earlier app runs.
final sessionUltraRunsProvider = Provider.family<List<UltraRunEntry>, String>((ref, sessionId) {
  final live = [
    for (final v in ref.watch(ultraRunsProvider).values)
      if (v.sessionId == sessionId) UltraRunEntry.fromView(v),
  ]..sort((a, b) => a.runId.compareTo(b.runId));
  final ids = {for (final e in live) e.runId};
  final saved = ref.watch(ultraSavedRunsProvider(sessionId)).value ?? const <UltraJournal>[];
  return [
    for (final j in saved)
      if (!ids.contains(j.runId)) UltraRunEntry.fromJournal(j),
    ...live,
  ];
});

/// Starts an Ultra run on [goal] under the session's caps and turns the
/// toggle off (one message, one run). Throws [UltraError] for the user.
Future<String> startUltraRun(WidgetRef ref, String sessionId, String goal) async {
  final toggle = ref.read(ultraToggleProvider(sessionId));
  final id = await ref.read(ultraRunsProvider.notifier).start(sessionId: sessionId, goal: goal, limits: toggle.limits);
  ref.read(ultraToggleProvider(sessionId).notifier).setArmed(false);
  return id;
}

/// Stops every active run of [sessionId]; returns how many.
int stopUltraRuns(WidgetRef ref, String sessionId) {
  final runs = ref.read(ultraRunsProvider.notifier);
  var n = 0;
  for (final e in ref.read(sessionUltraRunsProvider(sessionId))) {
    if (!e.active) continue;
    runs.stop(e.runId);
    n++;
  }
  return n;
}

/// The message that hands a finished run's answer to the session's own agent.
String ultraHandoff(UltraRunEntry e) =>
    'An Ultra run finished. Goal: ${e.goal.trim()}\n\nIts report:\n\n${e.answer.trim()}\n\n'
    'Read the report and carry on from it. Steps that changed files were merged into this worktree; branches it '
    'names as unmerged were left for review.';

/// Whether [sessionId] can show Ultra at all (not the scripted demo).
bool ultraSessionEligible(WidgetRef ref, String sessionId) {
  final info = ref.read(codeSessionsProvider.notifier).byId(sessionId);
  return info != null && !isDemoPath(info.workingDir) && !info.isSubagent;
}
