// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../harness/events.dart' show PlanWindow;

// What a workflow run will take, shown to the user before it starts (owner, 2026-11-08): agents from the workflow's
// own rules (its meta's `agents`), dollars on an EveryAI lead (from this project's past runs of it, else from the
// lead's model price), the plan windows' use now on an outside lead that reports them, and a time range from past runs
// as information only. Wall time is never a limit, and a lead with no plan limits gets no measure at all.

/// How many agents a workflow starts, from its meta: `agents: {fixed: [lo, hi], perItem: [lo, hi], items: 'items'}`
/// (`items` names the args list one entry per item; both parts optional).
@immutable
final class AgentRule {
  const AgentRule({this.fixed = (0, 0), this.perItem = (0, 0), this.itemsKey = 'items'});

  final (int, int) fixed;
  final (int, int) perItem;
  final String itemsKey;

  static AgentRule? of(Object? raw) {
    if (raw is! Map) return null;
    (int, int)? pair(Object? v) => switch (v) {
      [final num lo, final num hi] when lo >= 0 && hi >= lo => (lo.toInt(), hi.toInt()),
      final num n when n >= 0 => (n.toInt(), n.toInt()),
      _ => null,
    };
    final fixed = pair(raw['fixed']);
    final perItem = pair(raw['perItem']);
    if (fixed == null && perItem == null) return null;
    return AgentRule(
      fixed: fixed ?? (0, 0),
      perItem: perItem ?? (0, 0),
      itemsKey: raw['items'] is String ? raw['items'] as String : 'items',
    );
  }
}

/// One finished run of a workflow in a project, kept for the next estimate.
@immutable
final class PastRun {
  const PastRun({
    required this.workflow,
    required this.agents,
    required this.spentMicros,
    required this.took,
    this.everyai = true,
  });

  final String workflow;
  final int agents;

  /// What its agents cost EveryAI (0 on an outside lead).
  final int spentMicros;
  final Duration took;

  /// Led by the EveryAI harness (its spend counts toward dollar estimates).
  final bool everyai;

  Map<String, Object?> toJson() => {
    'workflow': workflow,
    'agents': agents,
    'spent_micros': spentMicros,
    'ms': took.inMilliseconds,
    if (!everyai) 'everyai': false,
  };

  static PastRun? fromJson(Object? j) => switch (j) {
    {'workflow': final String w, 'agents': final int a, 'spent_micros': final int s, 'ms': final int ms} => PastRun(
      workflow: w,
      agents: a,
      spentMicros: s,
      took: Duration(milliseconds: ms),
      everyai: (j as Map)['everyai'] != false,
    ),
    _ => null,
  };
}

/// The past runs kept per project (newest last), at most [keep].
List<PastRun> pastRunsOf(String? stored) {
  if (stored == null || stored.isEmpty) return const [];
  try {
    final list = jsonDecode(stored);
    return [
      if (list is List)
        for (final j in list) ?PastRun.fromJson(j),
    ];
  } on FormatException {
    return const [];
  }
}

String pastRunsWith(String? stored, PastRun run, {int keep = 30}) {
  final all = [...pastRunsOf(stored), run];
  return jsonEncode([for (final r in all.skip(math.max(0, all.length - keep))) r.toJson()]);
}

/// What a run of a workflow is expected to take.
@immutable
final class WorkflowEstimate {
  const WorkflowEstimate({
    this.agents,
    this.perItem,
    this.dollars,
    this.time,
    this.planWindows = const [],
    this.basis = '',
  });

  /// The agents it starts, low to high; null when its meta has no rule.
  final (int, int)? agents;

  /// When the items aren't known before it runs (a first agent splits the task): agents per item.
  final (int, int)? perItem;

  /// Dollars on an EveryAI lead, low to high (null on an outside lead, or with no price to go on).
  final (double, double)? dollars;

  /// From past runs only, as information.
  final (Duration, Duration)? time;

  /// An outside lead's plan windows as they are now (empty when it reports none).
  final List<PlanWindow> planWindows;

  /// Where the numbers come from ("from 3 past runs", "from Sonnet 5.5's price").
  final String basis;

  /// The top of [dollars] in micros: past it the run pauses and asks. None while the items aren't known ([perItem]):
  /// [dollars] is then one item's, and the run's total can't be told before it splits the task.
  int? get ceilingMicros => dollars == null || perItem != null ? null : (dollars!.$2 * 1e6).round();

  /// This estimate with the plan [windows] as they are now (the guard counts from a run's start).
  WorkflowEstimate withPlanWindows(List<PlanWindow> windows) => WorkflowEstimate(
    agents: agents,
    perItem: perItem,
    dollars: dollars,
    time: time,
    planWindows: windows,
    basis: basis,
  );

  Map<String, Object?> toJson() => {
    if (agents case (final lo, final hi)) 'agents': [lo, hi],
    if (perItem case (final lo, final hi)) 'per_item': [lo, hi],
    if (dollars case (final lo, final hi)) 'dollars': [lo, hi],
    if (time case (final lo, final hi)) 'time_ms': [lo.inMilliseconds, hi.inMilliseconds],
    if (planWindows.isNotEmpty) 'plan_windows': [for (final w in planWindows) w.toJson()],
    if (basis.isNotEmpty) 'basis': basis,
  };

  static WorkflowEstimate fromJson(Map<String, Object?> j) {
    (num, num)? pair(Object? v) => switch (v) {
      [final num a, final num b] => (a, b),
      _ => null,
    };
    final a = pair(j['agents']);
    final p = pair(j['per_item']);
    final d = pair(j['dollars']);
    final t = pair(j['time_ms']);
    return WorkflowEstimate(
      agents: a == null ? null : (a.$1.toInt(), a.$2.toInt()),
      perItem: p == null ? null : (p.$1.toInt(), p.$2.toInt()),
      dollars: d == null ? null : (d.$1.toDouble(), d.$2.toDouble()),
      time: t == null ? null : (Duration(milliseconds: t.$1.toInt()), Duration(milliseconds: t.$2.toInt())),
      planWindows: [
        if (j['plan_windows'] case final List<Object?> ws)
          for (final w in ws)
            if (w case {'name': final String n, 'used': final num u})
              PlanWindow(
                name: n,
                used: u.toDouble(),
                minutes: w['minutes'] as int?,
                resetsAt: w['resets_at'] is int
                    ? DateTime.fromMillisecondsSinceEpoch((w['resets_at']! as int) * 1000)
                    : null,
              ),
      ],
      basis: j['basis'] as String? ?? '',
    );
  }
}

/// What one agent costs on a model priced [promptPerMtok] / [completionPerMtok] (dollars per million tokens), by
/// the rule of thumb of a working agent: ~400K tokens read (most from the cache, at a tenth of the price) and ~12K
/// written.
double dollarsPerAgent(double promptPerMtok, double completionPerMtok) {
  const read = 400000.0, cachedShare = 0.85, written = 12000.0;
  final input = read * (1 - cachedShare) + read * cachedShare * 0.1;
  return (input * promptPerMtok + written * completionPerMtok) / 1e6;
}

/// The estimate for a run of [workflowId] (starting agents by [rule]) on [args]. [everyai]: led by the EveryAI harness, priced by
/// [past] runs of it, else by [price] (per million tokens, prompt and completion) of [modelName]; an outside lead
/// shows its [planWindows] instead.
WorkflowEstimate estimateWorkflow({
  required String workflowId,
  required AgentRule? rule,
  required Map<String, Object?> args,
  required bool everyai,
  List<PastRun> past = const [],
  (double, double)? price,
  String modelName = '',
  List<PlanWindow> planWindows = const [],
}) {
  (int, int)? agents;
  (int, int)? perItem;
  if (rule != null) {
    final items = args[rule.itemsKey];
    if (items is List && items.isNotEmpty) {
      agents = (rule.fixed.$1 + rule.perItem.$1 * items.length, rule.fixed.$2 + rule.perItem.$2 * items.length);
    } else if (rule.perItem.$2 > 0) {
      // Split by its first agent: the fixed part and a range per item.
      perItem = rule.perItem;
      agents = (rule.fixed.$1 + rule.perItem.$1, rule.fixed.$2 + rule.perItem.$2);
    } else {
      agents = rule.fixed;
    }
  }
  final mine = [
    for (final r in past)
      if (r.workflow == workflowId && r.agents > 0) r,
  ];
  // Dollars: an EveryAI lead's runs only (an outside lead's agents cost EveryAI nothing).
  (double, double)? dollars;
  var basis = '';
  final priced = [
    for (final r in mine)
      if (r.everyai && r.spentMicros > 0) r.spentMicros / 1e6 / r.agents,
  ];
  if (everyai && agents != null) {
    final double? each;
    if (priced.isNotEmpty) {
      each = priced.reduce((a, b) => a + b) / priced.length;
      basis = 'from ${priced.length} past run${priced.length == 1 ? '' : 's'} here';
    } else if (price != null && price.$1 >= 0 && price.$2 >= 0) {
      // (A router's negative price is no price: the shop shows none either.)
      each = dollarsPerAgent(price.$1, price.$2);
      basis = modelName.isEmpty ? "from the model's price" : "from $modelName's price";
    } else {
      each = null;
    }
    if (each != null) dollars = (agents.$1 * each * 0.6, agents.$2 * each * 1.4);
  }
  // Time, from past runs only: their time per agent, scaled.
  (Duration, Duration)? time;
  if (agents != null && mine.isNotEmpty) {
    final perAgent = mine.map((r) => r.took.inMilliseconds / r.agents).reduce((a, b) => a + b) / mine.length;
    time = (
      Duration(milliseconds: (perAgent * agents.$1 * 0.7).round()),
      Duration(milliseconds: (perAgent * agents.$2 * 1.3).round()),
    );
    if (basis.isEmpty) basis = 'from ${mine.length} past run${mine.length == 1 ? '' : 's'} here';
  }
  return WorkflowEstimate(
    agents: agents,
    perItem: perItem,
    dollars: dollars,
    time: time,
    planWindows: everyai ? const [] : planWindows,
    basis: basis,
  );
}

String _dollars(double d) => d < 10 ? '\$${d.toStringAsFixed(2)}' : '\$${d.round()}';

String _minutes(Duration d) {
  final m = (d.inSeconds / 60).ceil();
  return m < 60 ? '$m min' : '${(m / 60).toStringAsFixed(m % 60 == 0 ? 0 : 1)} h';
}

/// The estimate's numbers in one line ("~13–16 agents · $1.80–3.10 · 30–45 min").
String estimateLine(WorkflowEstimate e) {
  String range((int, int) r) => r.$1 == r.$2 ? '${r.$1}' : '${r.$1}–${r.$2}';
  return [
    if (e.agents case final a?)
      e.perItem == null ? '~${range(a)} agents' : '~${range(a)} agents for one item (${range(e.perItem!)} each)',
    if (e.dollars case (final lo, final hi))
      '${_dollars(lo)}–${_dollars(hi).substring(1)}${e.perItem == null ? '' : ' per item'}',
    if (e.time case (final lo, final hi)) '${_minutes(lo)}–${_minutes(hi)}',
  ].join(' · ');
}
