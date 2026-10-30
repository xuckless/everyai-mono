import 'dart:convert';

import 'ultra_plan.dart';

/// Where an Ultra run stands. Saved to disk after every change, so a run the
/// app lost (quit, crash) picks up where it was: finished steps are kept and
/// running ones are reattached or started again.
enum UltraRunStatus {
  running,

  /// Every phase (and the critic's extra phase) has finished.
  done,

  /// A cap was hit: agents, dollars, wall time or the wallet.
  capped,

  /// The user stopped it.
  stopped,

  /// It could not run (refused plan, not on Max, empty wallet).
  failed;

  bool get over => this != running;

  static UltraRunStatus parse(Object? s) => values.where((v) => v.name == s).firstOrNull ?? running;
}

enum StepStatus {
  pending,
  running,
  done,
  failed,

  /// Never started: a cap, a stop, or an earlier pipeline stage failed.
  skipped,

  /// Stopped while it ran.
  stopped;

  bool get over => this != pending && this != running;

  static StepStatus parse(Object? s) => values.where((v) => v.name == s).firstOrNull ?? pending;
}

/// What happened to a writing step's worktree.
final class MergeOutcome {
  const MergeOutcome({required this.merged, required this.branch, this.detail = ''});

  final bool merged;

  /// Left in place when it couldn't be merged, for the user.
  final String branch;
  final String detail;

  Map<String, Object?> toJson() => {'merged': merged, 'branch': branch, if (detail.isNotEmpty) 'detail': detail};

  static MergeOutcome? fromJson(Object? j) => switch (j) {
    {'merged': final bool merged, 'branch': final String branch} => MergeOutcome(
      merged: merged,
      branch: branch,
      detail: (j as Map)['detail'] as String? ?? '',
    ),
    _ => null,
  };
}

/// A worktree made for one writing step.
final class StepWorktree {
  const StepWorktree({required this.path, required this.branch});
  final String path;
  final String branch;

  Map<String, Object?> toJson() => {'path': path, 'branch': branch};

  static StepWorktree? fromJson(Object? j) => switch (j) {
    {'path': final String path, 'branch': final String branch} => StepWorktree(path: path, branch: branch),
    _ => null,
  };
}

/// One run of one step (for one item).
final class StepRecord {
  StepRecord({
    required this.key,
    required this.phaseId,
    required this.stepId,
    required this.title,
    this.item,
    this.status = StepStatus.pending,
    this.attempts = 0,
    this.childIds = const [],
    this.worktree,
    this.output = '',
    this.structured,
    this.schemaErrors = const [],
    this.verified,
    this.verifyNotes = '',
    this.merge,
    this.costMicros = 0,
    this.note = '',
    this.startedAt,
    this.endedAt,
  });

  /// `phase.step`, or `phase.step[i]` for item i of a `for_each`.
  final String key;
  final String phaseId;
  final String stepId;
  final String title;
  final String? item;

  StepStatus status;
  int attempts;

  /// Every child it started (step attempts and verifiers), newest last.
  List<String> childIds;
  StepWorktree? worktree;

  /// The child's final message.
  String output;

  /// Its ```json block, when the step has a result schema.
  Object? structured;
  List<String> schemaErrors;

  /// The verifier's verdict; null when there is none (yet).
  bool? verified;
  String verifyNotes;
  MergeOutcome? merge;

  /// What its children cost, settled once they finish.
  int costMicros;

  /// Why it was skipped, failed or stopped.
  String note;

  /// When its first child started, and when it settled (null while it runs).
  DateTime? startedAt;
  DateTime? endedAt;

  /// What its running children have cost so far (settled into [costMicros]
  /// once they finish). Saved, so a run cut off mid-step still counts it.
  int liveCostMicros = 0;

  /// Settled plus live cost, for the progress tree.
  int get shownCostMicros => costMicros + liveCostMicros;

  /// How long it has run, or ran; null before it starts.
  Duration? elapsedAt(DateTime now) => switch (startedAt) {
    null => null,
    final start => (endedAt ?? now).difference(start),
  };

  /// The result later steps and the orchestrator read: the JSON when there is
  /// one, else the text.
  String get result => structured == null ? output : _json(structured);

  Map<String, Object?> toJson() => {
    'key': key,
    'phase': phaseId,
    'step': stepId,
    'title': title,
    'item': ?item,
    'status': status.name,
    'attempts': attempts,
    if (childIds.isNotEmpty) 'children': childIds,
    'worktree': ?worktree?.toJson(),
    if (output.isNotEmpty) 'output': output,
    'structured': ?structured,
    if (schemaErrors.isNotEmpty) 'schema_errors': schemaErrors,
    'verified': ?verified,
    if (verifyNotes.isNotEmpty) 'verify_notes': verifyNotes,
    'merge': ?merge?.toJson(),
    'cost_micros': costMicros,
    if (liveCostMicros > 0) 'live_cost_micros': liveCostMicros,
    if (note.isNotEmpty) 'note': note,
    'started_at': ?startedAt?.toUtc().toIso8601String(),
    'ended_at': ?endedAt?.toUtc().toIso8601String(),
  };

  factory StepRecord.fromJson(Map<String, Object?> j) => StepRecord(
    key: j['key']! as String,
    phaseId: j['phase'] as String? ?? '',
    stepId: j['step'] as String? ?? '',
    title: j['title'] as String? ?? '',
    item: j['item'] as String?,
    status: StepStatus.parse(j['status']),
    attempts: (j['attempts'] as num?)?.toInt() ?? 0,
    childIds: [...((j['children'] as List?) ?? const []).whereType<String>()],
    worktree: StepWorktree.fromJson(j['worktree']),
    output: j['output'] as String? ?? '',
    structured: j['structured'],
    schemaErrors: [...((j['schema_errors'] as List?) ?? const []).whereType<String>()],
    verified: j['verified'] as bool?,
    verifyNotes: j['verify_notes'] as String? ?? '',
    merge: MergeOutcome.fromJson(j['merge']),
    costMicros: (j['cost_micros'] as num?)?.toInt() ?? 0,
    note: j['note'] as String? ?? '',
    startedAt: DateTime.tryParse(j['started_at'] as String? ?? '')?.toLocal(),
    endedAt: DateTime.tryParse(j['ended_at'] as String? ?? '')?.toLocal(),
  )..liveCostMicros = (j['live_cost_micros'] as num?)?.toInt() ?? 0;
}

/// The persisted state of one Ultra run.
final class UltraJournal {
  UltraJournal({
    required this.runId,
    required this.sessionId,
    required this.plan,
    required this.limits,
    required this.createdAt,
    this.orchestratorId = '',
    this.planCallId = '',
    this.status = UltraRunStatus.running,
    this.elapsed = Duration.zero,
    this.budgetMicros = 0,
    this.agentsStarted = 0,
    this.orchestratorMicros = 0,
    Map<String, StepRecord>? steps,
    this.gaps,
    this.criticDone = false,
    this.complete,
    this.criticNotes = '',
    this.note = '',
  }) : steps = steps ?? {};

  final String runId;

  /// The Code session the run belongs to (its worktree is the base).
  final String sessionId;

  /// The orchestrator's child session, and its `ultra_plan` call.
  String orchestratorId;
  String planCallId;
  final UltraPlan plan;
  final UltraLimits limits;
  final DateTime createdAt;

  UltraRunStatus status;

  /// Wall time spent so far (summed across resumes).
  Duration elapsed;

  /// The run's cap: the limit, or less when the wallet held less at the start.
  int budgetMicros;
  int agentsStarted;

  /// What the orchestrator has cost (planning, plans sent back); it counts
  /// against [budgetMicros] with the steps.
  int orchestratorMicros;

  /// By [StepRecord.key], plus `_critic` for the critic.
  final Map<String, StepRecord> steps;

  /// The extra phase the critic asked for, once it has.
  UltraPhase? gaps;
  bool criticDone;

  /// The critic's verdict.
  bool? complete;
  String criticNotes;

  /// Why the run ended, when it ended early.
  String note;

  int get spentMicros => orchestratorMicros + steps.values.fold(0, (n, s) => n + s.costMicros);

  /// The phases to run, the critic's extra one last.
  List<UltraPhase> get phases => [...plan.phases, ?gaps];

  Map<String, Object?> toJson() => {
    'version': 1,
    'run_id': runId,
    'session_id': sessionId,
    'orchestrator_id': orchestratorId,
    'plan_call_id': planCallId,
    'plan': plan.toJson(),
    'limits': limits.toJson(),
    'created_at': createdAt.toUtc().toIso8601String(),
    'status': status.name,
    'elapsed_ms': elapsed.inMilliseconds,
    'budget_micros': budgetMicros,
    'agents_started': agentsStarted,
    if (orchestratorMicros > 0) 'orchestrator_micros': orchestratorMicros,
    'steps': [for (final s in steps.values) s.toJson()],
    'gaps': ?gaps?.toJson(),
    'critic_done': criticDone,
    'complete': ?complete,
    if (criticNotes.isNotEmpty) 'critic_notes': criticNotes,
    if (note.isNotEmpty) 'note': note,
  };

  /// Null when [j] isn't a journal this version can read.
  static UltraJournal? fromJson(Map<String, Object?> j) {
    final plan = parseUltraPlan(j['plan']).plan;
    if (plan == null || j['run_id'] is! String) return null;
    final gaps = switch (j['gaps']) {
      // Parsed after the plan's phases, which its steps read.
      final Map<String, Object?> g => parseUltraPlan({
        ...plan.toJson(),
        'phases': [...plan.toJson()['phases']! as List<Object?>, g],
      }).plan?.phases.last,
      _ => null,
    };
    return UltraJournal(
      runId: j['run_id']! as String,
      sessionId: j['session_id'] as String? ?? '',
      orchestratorId: j['orchestrator_id'] as String? ?? '',
      planCallId: j['plan_call_id'] as String? ?? '',
      plan: plan,
      limits: UltraLimits.fromJson((j['limits'] as Map<String, Object?>?) ?? const {}),
      createdAt: DateTime.tryParse(j['created_at'] as String? ?? '') ?? DateTime.now(),
      status: UltraRunStatus.parse(j['status']),
      elapsed: Duration(milliseconds: (j['elapsed_ms'] as num?)?.toInt() ?? 0),
      budgetMicros: (j['budget_micros'] as num?)?.toInt() ?? 0,
      agentsStarted: (j['agents_started'] as num?)?.toInt() ?? 0,
      orchestratorMicros: (j['orchestrator_micros'] as num?)?.toInt() ?? 0,
      steps: {
        for (final s in (j['steps'] as List?) ?? const [])
          if (s is Map<String, Object?> && s['key'] is String) s['key']! as String: StepRecord.fromJson(s),
      },
      gaps: gaps,
      criticDone: j['critic_done'] == true,
      complete: j['complete'] as bool?,
      criticNotes: j['critic_notes'] as String? ?? '',
      note: j['note'] as String? ?? '',
    );
  }
}

String _json(Object? v) {
  try {
    return const JsonEncoder.withIndent('  ').convert(v);
  } on Object {
    return '$v';
  }
}
