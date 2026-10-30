import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'ultra_journal.dart';
import 'ultra_plan.dart';
import 'ultra_prompts.dart';

/// What a child conversation is for.
enum ChildRole { step, verify, critic }

/// How a child's turn ended.
enum ChildEnd { completed, failed, stopped }

final class ChildResult {
  const ChildResult(this.end, this.text);
  final ChildEnd end;

  /// Its final message (or the error).
  final String text;

  bool get ok => end == ChildEnd.completed;
}

/// A child conversation the engine wants started.
final class UltraChildRequest {
  const UltraChildRequest({
    required this.key,
    required this.title,
    required this.brief,
    required this.role,
    required this.fallbackModel,
    this.model,
    this.effort,
    this.agent,
    this.workingDir,
    this.writes = false,
  });

  /// The journal key it works for.
  final String key;
  final String title;
  final String brief;
  final ChildRole role;

  /// The plan's model, or null to use the agent's or [fallbackModel].
  final String? model;
  final String fallbackModel;
  final String? effort;
  final String? agent;

  /// Its own worktree; null runs it in the session's folder.
  final String? workingDir;

  /// May change files (else it runs read-only).
  final bool writes;
}

/// A running child conversation.
abstract interface class UltraChild {
  String get id;

  /// Completes when its current turn ends (finished, failed or stopped).
  Future<ChildResult> get result;

  /// What it has cost so far.
  int get costMicros;

  /// Sends one more message and waits for the turn it starts.
  Future<ChildResult> followUp(String message);
  Future<void> stop();
}

/// Starts child conversations (the app: `CodeSessions.startChild`; tests: a fake).
abstract interface class UltraChildRunner {
  Future<UltraChild> start(UltraChildRequest request);

  /// Stops a child a lost run left behind (best effort) and returns
  /// everything it cost, or null when that can't be read.
  Future<int?> abandon(String childId);

  /// A child's turns are over: ends the background processes it left
  /// running (dev servers, watchers), best effort.
  Future<void> release(String childId);
}

final class WalletReading {
  const WalletReading({required this.planId, required this.availableMicros});
  final String planId;

  /// Prepaid wallet plus what is left of the plan's monthly quota.
  final int availableMicros;
}

/// `GET /v1/billing`.
abstract interface class UltraWallet {
  Future<WalletReading> read();
}

/// Worktrees for writing steps.
abstract interface class UltraWorkspace {
  /// False when the session's folder isn't a git repository: writing steps
  /// then run in it one at a time.
  bool get isolates;

  Future<StepWorktree> create(String runId, String key);

  /// Merges [w] into the session's worktree; on a conflict the branch stays.
  Future<MergeOutcome> merge(StepWorktree w, String message);
}

abstract interface class UltraJournalStore {
  Future<void> save(UltraJournal journal);
  Future<UltraJournal?> load(String runId);
}

/// Runs an [UltraJournal]'s plan: phases in order, children capped by the
/// run's limits and the wallet, everything written to the journal as it
/// happens. Deterministic given the children's answers.
final class UltraEngine {
  UltraEngine({
    required this.journal,
    required this.runner,
    required this.wallet,
    required this.workspace,
    required this.store,
    this.allowWrites = true,
    DateTime Function()? clock,
    this.checkEvery = const Duration(seconds: 5),
    this.walletEvery = const Duration(seconds: 60),
    this.onChange,
    this.orchestratorCost,
  }) : _clock = clock ?? DateTime.now,
       _slots = _Slots(journal.limits.maxConcurrent);

  final UltraJournal journal;
  final UltraChildRunner runner;
  final UltraWallet wallet;
  final UltraWorkspace workspace;
  final UltraJournalStore store;

  /// False in Plan mode: no step may change files.
  final bool allowWrites;
  final Duration checkEvery;
  final Duration walletEvery;

  /// Called after every journal change, for the UI.
  final void Function(UltraJournal journal)? onChange;

  /// What the orchestrator (planning, rejected plans) has cost so far, read
  /// at the start and with the wallet; it counts against the run's cap.
  final Future<int?> Function()? orchestratorCost;
  final DateTime Function() _clock;

  final _Slots _slots;
  final _git = _Lock();
  final _writer = _Lock();
  final _active = <String, UltraChild>{};
  Future<void> _saving = Future.value();
  late DateTime _startedAt;
  late Duration _before;
  DateTime? _walletAt;
  Timer? _timer;
  bool _checkingWallet = false;
  ({UltraRunStatus status, String note})? _halt;
  int _finishedChildren = 0;
  int _finishedCost = 0;

  UltraLimits get limits => journal.limits;

  /// Spend so far, counting children still running.
  int get spentMicros => journal.spentMicros + _active.values.fold(0, (n, c) => n + c.costMicros);

  Duration get elapsed => _before + _clock().difference(_startedAt);

  /// Stops the run: running children are stopped, the rest skipped.
  void stop() => _haltWith(UltraRunStatus.stopped, 'The user stopped the run.');

  Future<UltraJournal> run() async {
    if (journal.status.over) return journal;
    _startedAt = _clock();
    _before = journal.elapsed;
    // A resumed run: what was cut off runs again, from a fresh child. What
    // the cut-off children spent still counts: each child's ledger total
    // (settled ones included) replaces the step's sum when it is higher.
    for (final s in journal.steps.values) {
      if (s.status == StepStatus.running) {
        final costs = await Future.wait([
          for (final id in s.childIds) runner.abandon(id).then((c) => c, onError: (Object _) => null),
        ]);
        final known = costs.every((c) => c != null);
        s
          ..costMicros = known
              ? math.max(s.costMicros, costs.fold<int>(0, (n, c) => n + c!))
              : s.costMicros + s.liveCostMicros
          ..liveCostMicros = 0;
      }
      if (s.status == StepStatus.running || s.status == StepStatus.skipped || s.status == StepStatus.stopped) {
        s
          ..status = StepStatus.pending
          ..note = '';
      }
    }
    if (!await _admit()) return _finish();
    _timer = Timer.periodic(checkEvery, (_) => _check());
    try {
      for (final phase in journal.plan.phases) {
        if (_halt != null) break;
        await _runPhase(phase);
      }
      if (_halt == null && !journal.criticDone) await _runCritic();
      if (_halt == null && journal.gaps != null) await _runPhase(journal.gaps!);
    } finally {
      _timer?.cancel();
    }
    return _finish();
  }

  Future<void> _readOrchestrator() async {
    final read = orchestratorCost;
    if (read == null) return;
    try {
      final cost = await read();
      if (cost != null && cost > journal.orchestratorMicros) journal.orchestratorMicros = cost;
    } on Object {
      // The last reading stands.
    }
  }

  /// The Max plan gate and the wallet check before anything starts.
  Future<bool> _admit() async {
    await _readOrchestrator();
    final WalletReading w;
    try {
      w = await wallet.read();
    } on Object catch (e) {
      _haltWith(UltraRunStatus.failed, "Couldn't read the wallet: $e");
      return false;
    }
    _walletAt = _clock();
    if (!ultraAllowedOn(w.planId)) {
      _haltWith(UltraRunStatus.failed, 'Ultra runs are part of the Max plan.');
      return false;
    }
    if (w.availableMicros <= 0) {
      _haltWith(UltraRunStatus.failed, 'There is no credit left for an Ultra run. Top up or wait for the quota.');
      return false;
    }
    final cap = journal.budgetMicros > 0 ? journal.budgetMicros : limits.budgetMicros;
    journal.budgetMicros = math.min(cap, journal.spentMicros + w.availableMicros);
    if (journal.spentMicros >= journal.budgetMicros) {
      _haltWith(UltraRunStatus.capped, 'The run had already used its budget.');
      return false;
    }
    if (elapsed >= limits.wallTime) {
      _haltWith(UltraRunStatus.capped, 'The run had already used its time.');
      return false;
    }
    _save();
    return true;
  }

  Future<UltraJournal> _finish() async {
    _timer?.cancel();
    for (final s in journal.steps.values) {
      if (s.status == StepStatus.pending || s.status == StepStatus.running) {
        s
          ..status = s.status == StepStatus.running ? StepStatus.stopped : StepStatus.skipped
          ..note = s.note.isEmpty ? (_halt?.note ?? 'Not reached.') : s.note;
      }
    }
    journal
      ..status = _halt?.status ?? (_capped == null ? UltraRunStatus.done : UltraRunStatus.capped)
      ..note = _halt?.note ?? _capped ?? '';
    if (_halt == null || journal.status != UltraRunStatus.failed) journal.elapsed = elapsed;
    _save();
    await _saving;
    return journal;
  }

  /// Caps checked on a timer and after every child: money, time, the wallet.
  void _check() {
    if (_halt != null) return;
    // The progress tree's clock and running costs, without a disk write.
    journal.elapsed = elapsed;
    _stamp();
    onChange?.call(journal);
    if (spentMicros >= journal.budgetMicros) {
      _haltWith(UltraRunStatus.capped, 'The run reached its \$${(journal.budgetMicros / 1e6).toStringAsFixed(2)} cap.');
    } else if (elapsed >= limits.wallTime) {
      _haltWith(UltraRunStatus.capped, 'The run reached its ${limits.wallTime.inMinutes}-minute limit.');
    } else if (!_checkingWallet && _clock().difference(_walletAt ?? _startedAt) >= walletEvery) {
      _checkingWallet = true;
      _walletAt = _clock();
      unawaited(
        wallet
            .read()
            .then((w) {
              if (w.availableMicros <= 0) _haltWith(UltraRunStatus.capped, 'The wallet ran out during the run.');
            })
            .catchError((Object _) {})
            .then((_) => _readOrchestrator())
            .whenComplete(() => _checkingWallet = false),
      );
    }
  }

  void _haltWith(UltraRunStatus status, String note) {
    if (_halt != null) return;
    _halt = (status: status, note: note);
    for (final c in [..._active.values]) {
      unawaited(c.stop().catchError((Object _) {}));
    }
  }

  /// Why no more children start, once a cap is near: the agent cap, or a
  /// budget without room for an average child. Children already running
  /// finish (unlike a halt).
  String? _capped;

  String? _whyNot() {
    if (_capped != null) return _capped;
    final average = _finishedChildren == 0 ? 0 : _finishedCost ~/ _finishedChildren;
    if (journal.agentsStarted >= limits.maxAgents) {
      _capped = 'The run reached its ${limits.maxAgents}-agent cap.';
    } else if (spentMicros + average > journal.budgetMicros) {
      _capped = 'The rest of the budget would not cover another agent.';
    }
    return _capped;
  }

  Future<void> _runPhase(UltraPhase phase) async {
    final items = phase.forEach.isEmpty ? const <String?>[null] : phase.forEach;
    if (phase.fanOut == FanOut.parallel) {
      await Future.wait([
        for (final (i, item) in items.indexed)
          for (final step in phase.steps) _runStep(phase, step, item == null ? null : i, item),
      ]);
      return;
    }
    await Future.wait([
      for (final (i, item) in items.indexed)
        () async {
          String? previous;
          for (final (n, step) in phase.steps.indexed) {
            final rec = await _runStep(phase, step, item == null ? null : i, item, previous: previous);
            if (rec.status != StepStatus.done) {
              for (final later in phase.steps.skip(n + 1)) {
                _record(phase, later, item == null ? null : i, item)
                  ..status = StepStatus.skipped
                  ..note = 'An earlier stage (${rec.key}) did not finish.';
              }
              _save();
              return;
            }
            previous = rec.key;
          }
        }(),
    ]);
  }

  static String keyOf(String phase, String step, int? index) => index == null ? '$phase.$step' : '$phase.$step[$index]';

  StepRecord _record(UltraPhase phase, UltraStep step, int? index, String? item) {
    final key = keyOf(phase.id, step.id, index);
    return journal.steps.putIfAbsent(
      key,
      () => StepRecord(key: key, phaseId: phase.id, stepId: step.id, title: step.title, item: item),
    );
  }

  /// The results [step] reads: its `inputs`, and in a pipeline the stage before.
  Map<String, String> _inputsOf(UltraPhase phase, UltraStep step, int? index, String? previous) {
    final out = <String, String>{};
    void add(StepRecord r) => out[r.key] = r.status == StepStatus.done ? r.result : '(${r.status.name}) ${r.note}';
    for (final ref in step.inputs) {
      final dot = ref.indexOf('.');
      final p = dot < 0 ? ref : ref.substring(0, dot);
      final s = dot < 0 ? null : ref.substring(dot + 1);
      for (final r in journal.steps.values) {
        if (r.phaseId != p || (s != null && r.stepId != s)) continue;
        // In its own phase it reads the same item's stage only.
        if (p == phase.id && index != null && r.key != keyOf(p, r.stepId, index)) continue;
        add(r);
      }
    }
    if (previous != null) {
      if (journal.steps[previous] case final r?) add(r);
    }
    return out;
  }

  Future<StepRecord> _runStep(UltraPhase phase, UltraStep step, int? index, String? item, {String? previous}) async {
    final rec = _record(phase, step, index, item);
    if (rec.status.over) return rec;
    final inputs = _inputsOf(phase, step, index, previous);
    final writes = step.writes && allowWrites;
    final isolated = writes && workspace.isolates;
    // Without worktrees, writers take turns in the session's folder.
    return writes && !isolated
        ? _writer.run(() => _attempts(phase, step, rec, item, inputs, writes: true, isolated: false))
        : _attempts(phase, step, rec, item, inputs, writes: writes, isolated: isolated);
  }

  Future<StepRecord> _attempts(
    UltraPhase phase,
    UltraStep step,
    StepRecord rec,
    String? item,
    Map<String, String> inputs, {
    required bool writes,
    required bool isolated,
  }) async {
    var retryNotes = '';
    while (true) {
      if (_halt != null) return rec;
      if (isolated && rec.worktree == null) {
        try {
          rec.worktree = await _git.run(() => workspace.create(journal.runId, rec.key));
          _save();
        } on Object catch (e) {
          rec
            ..status = StepStatus.failed
            ..note = "Couldn't make a worktree: $e";
          _save();
          return rec;
        }
      }
      rec.attempts++;
      final run = await _runChild(
        UltraChildRequest(
          key: rec.key,
          title: rec.item == null ? step.title : '${step.title}: ${rec.item}',
          brief: stepBrief(
            plan: journal.plan,
            phase: phase,
            step: step,
            item: item,
            inputs: inputs,
            isolated: isolated,
            retryNotes: retryNotes,
          ),
          role: ChildRole.step,
          model: step.model,
          fallbackModel: ultraStepModel,
          effort: step.effort,
          agent: step.agent,
          workingDir: rec.worktree?.path,
          writes: writes,
        ),
        rec,
        schema: step.resultSchema,
      );
      if (run == null) return rec;
      rec
        ..output = run.result.text
        ..structured = run.structured
        ..schemaErrors = run.schemaErrors;
      if (!run.result.ok) {
        rec
          ..status = run.result.end == ChildEnd.stopped ? StepStatus.stopped : StepStatus.failed
          ..note = run.result.end == ChildEnd.stopped ? (_halt?.note ?? 'Stopped.') : 'The agent failed.';
        _save();
        return rec;
      }
      if (step.verify != null) {
        final verdict = await _verify(step, rec);
        if (verdict == null) return rec;
        rec
          ..verified = verdict.pass
          ..verifyNotes = verdict.notes;
        if (!verdict.pass && rec.attempts <= limits.verifyRetries) {
          retryNotes = verdict.notes;
          _save();
          continue;
        }
      }
      if (rec.worktree case final w? when rec.merge == null) {
        rec.merge = await _git.run(() async {
          try {
            return await workspace.merge(w, 'Ultra: ${rec.title}${rec.item == null ? '' : ' (${rec.item})'}');
          } on Object catch (e) {
            return MergeOutcome(merged: false, branch: w.branch, detail: '$e');
          }
        });
      }
      rec.status = StepStatus.done;
      _save();
      return rec;
    }
  }

  /// Runs [step]'s verifier on [rec]; null when it could not run (a cap).
  Future<({bool pass, String notes})?> _verify(UltraStep step, StepRecord rec) async {
    final v = step.verify!;
    final run = await _runChild(
      UltraChildRequest(
        key: rec.key,
        title: 'Check: ${rec.title}',
        brief: verifyBrief(plan: journal.plan, step: step, record: rec),
        role: ChildRole.verify,
        model: v.model,
        fallbackModel: ultraVerifyModel,
        effort: v.effort,
        agent: v.agent,
        workingDir: rec.worktree?.path,
      ),
      rec,
      schema: verifySchema,
    );
    if (run == null) return null;
    if (!run.result.ok || run.structured is! Map) {
      // A checker that couldn't decide doesn't pass the step, nor rerun it.
      return (pass: false, notes: 'The check did not finish: ${_short(run.result.text)}');
    }
    final m = run.structured! as Map;
    final issues = [for (final i in (m['issues'] as List?) ?? const []) '- $i'];
    return (pass: m['pass'] == true, notes: issues.join('\n'));
  }

  Future<void> _runCritic() async {
    final rec = journal.steps.putIfAbsent(
      criticKey,
      () => StepRecord(key: criticKey, phaseId: '', stepId: criticKey, title: 'Completeness check'),
    );
    final room = limits.maxAgents - journal.agentsStarted - 1;
    final maxGaps = math.min(8, room);
    final run = await _runChild(
      UltraChildRequest(
        key: criticKey,
        title: 'Completeness check',
        brief: criticBrief(journal, allowWrites: allowWrites, maxGaps: math.max(0, maxGaps)),
        role: ChildRole.critic,
        model: journal.plan.critic.model,
        fallbackModel: ultraCriticModel,
        effort: journal.plan.critic.effort,
      ),
      rec,
      schema: criticSchema,
    );
    if (run == null) return;
    journal.criticDone = true;
    rec
      ..output = run.result.text
      ..structured = run.structured
      ..status = run.result.ok ? StepStatus.done : StepStatus.failed;
    if (run.structured case final Map<Object?, Object?> m when run.result.ok) {
      journal
        ..complete = m['complete'] == true
        ..criticNotes = '${m['notes'] ?? ''}'.trim();
      final gaps = [
        for (final g in (m['gaps'] as List?) ?? const [])
          if (g is Map && '${g['prompt'] ?? ''}'.trim().isNotEmpty) g,
      ].take(math.max(0, maxGaps)).toList();
      if (gaps.isNotEmpty) {
        final used = journal.plan.phases.map((p) => p.id).toSet();
        var id = 'critic-gaps';
        for (var n = 2; used.contains(id); n++) {
          id = 'critic-gaps-$n';
        }
        journal.gaps = UltraPhase(
          id: id,
          title: 'Gaps the critic found',
          steps: [
            for (final (i, g) in gaps.indexed)
              UltraStep(
                id: 'gap-${i + 1}',
                title: '${g['title'] ?? 'Gap ${i + 1}'}'.trim(),
                prompt: '${g['prompt']}'.trim(),
                writes: g['writes'] == true && allowWrites,
                inputs: [for (final p in journal.plan.phases) p.id],
              ),
          ],
        );
      }
    }
    _save();
  }

  /// One child, in a concurrency slot: started (if the caps allow), awaited,
  /// asked once more for its ```json block when that was missing or wrong.
  /// Null when it was never started (a cap, or the run halted).
  Future<({ChildResult result, Object? structured, List<String> schemaErrors})?> _runChild(
    UltraChildRequest request,
    StepRecord rec, {
    Map<String, Object?>? schema,
  }) async {
    await _slots.acquire();
    UltraChild? child;
    try {
      if (_halt != null) return null;
      if (_whyNot() case final why?) {
        rec
          ..status = StepStatus.skipped
          ..note = why;
        _save();
        return null;
      }
      journal.agentsStarted++;
      rec.status = StepStatus.running;
      try {
        child = await runner.start(request);
      } on Object catch (e) {
        rec.status = StepStatus.pending;
        _save();
        return (
          result: ChildResult(ChildEnd.failed, "The agent couldn't start: $e"),
          structured: null,
          schemaErrors: const <String>[],
        );
      }
      rec.childIds = [...rec.childIds, child.id];
      _active[child.id] = child;
      _save();
      if (_halt != null) unawaited(child.stop().catchError((Object _) {}));
      var result = await child.result;
      Object? structured;
      var errors = const <String>[];
      if (schema != null && result.ok) {
        (structured, errors) = _parse(result.text, schema);
        if (errors.isNotEmpty && _halt == null) {
          result = await child.followUp(_repair(errors, schema));
          if (result.ok) (structured, errors) = _parse(result.text, schema);
        }
      }
      return (result: result, structured: structured, schemaErrors: errors);
    } finally {
      if (child != null) {
        _active.remove(child.id);
        unawaited(runner.release(child.id).catchError((Object _) {}));
        final cost = child.costMicros;
        rec
          ..costMicros += cost
          ..liveCostMicros = 0;
        _finishedChildren++;
        _finishedCost += cost;
      }
      _slots.release();
      _save();
      _check();
    }
  }

  static (Object?, List<String>) _parse(String text, Map<String, Object?> schema) {
    final r = structuredResult(text);
    if (!r.found) return (null, const ['The final message has no ```json block.']);
    final errors = checkSchema(r.value, schema);
    return (errors.isEmpty ? r.value : null, errors);
  }

  static String _repair(List<String> errors, Map<String, Object?> schema) =>
      'Your final message has to end with one ```json block that matches the schema you were given. Problems:\n'
      '${errors.take(10).map((e) => '- $e').join('\n')}\n'
      'Reply with the corrected result only; do not redo the work.';

  static String _short(String s) => s.length <= 300 ? s : '${s.substring(0, 300)}…';

  void _save() {
    journal.elapsed = _halt?.status == UltraRunStatus.failed ? journal.elapsed : elapsed;
    _stamp();
    _saving = _saving.then((_) => store.save(journal)).catchError((Object _) {});
    onChange?.call(journal);
  }

  /// Start and end times, and what running children have cost so far.
  void _stamp() {
    final now = _clock();
    for (final s in journal.steps.values) {
      switch (s.status) {
        case StepStatus.running:
          s
            ..startedAt ??= now
            ..endedAt = null
            ..liveCostMicros = s.childIds.fold(0, (n, id) => n + (_active[id]?.costMicros ?? 0));
        case StepStatus.pending:
          s
            ..endedAt = null
            ..liveCostMicros = 0;
        default:
          if (s.startedAt != null) s.endedAt ??= now;
          s.liveCostMicros = 0;
      }
    }
  }
}

/// A counting semaphore.
final class _Slots {
  _Slots(this._free);
  int _free;
  final _waiting = Queue<Completer<void>>();

  Future<void> acquire() {
    if (_free > 0) {
      _free--;
      return Future.value();
    }
    final c = Completer<void>();
    _waiting.add(c);
    return c.future;
  }

  void release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    } else {
      _free++;
    }
  }
}

/// Runs one body at a time.
final class _Lock {
  final _slots = _Slots(1);

  Future<T> run<T>(Future<T> Function() body) async {
    await _slots.acquire();
    try {
      return await body();
    } finally {
      _slots.release();
    }
  }
}
