import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/router.dart';
import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/brand.dart';
import '../../../../core/ui/every_icons.dart';
import '../../../billing/billing_providers.dart' show formatMicros;
import '../../../chat/ui/chat_markdown.dart';
import '../../code_providers.dart';
import '../domain/ultra_journal.dart';
import '../domain/ultra_plan.dart';
import '../domain/ultra_prompts.dart' show criticKey;
import '../ultra_providers.dart';
import '../ultra_ui_providers.dart';
import 'ultra_toggle.dart' show formatUltraDuration;

/// The Ultra runs of a session, for the bottom of its transcript.
List<Widget> ultraRunCards(WidgetRef ref, String sessionId) => [
  for (final e in ref.watch(sessionUltraRunsProvider(sessionId)))
    UltraRunCard(key: ValueKey('ultra.${e.runId}'), entry: e),
];

/// One Ultra run as a live tree: the run's totals against its caps, then each
/// phase with an agent card per step (status, cost, time, "Open"), the
/// completeness check, and the answer. Stop while it runs; Resume once a
/// quit or a stop cut it off.
class UltraRunCard extends ConsumerWidget {
  const UltraRunCard({super.key, required this.entry});

  final UltraRunEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final j = entry.journal;
    return _Ticker(
      active: entry.active,
      builder: (context, now) => Container(
        decoration: BoxDecoration(
          border: Border.all(color: entry.active ? theme.accent.withValues(alpha: 0.5) : theme.border),
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (entry.active)
                  const EveryMarkActivity(activity: MarkActivity.tool, size: 14)
                else
                  AdaptiveIcon(EveryIcon.spark, size: 14, color: theme.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Ultra · ${_firstLine(entry.goal)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.type.callout.semibold.tint(theme.text),
                  ),
                ),
                if (entry.orchestratorId.isNotEmpty && _exists(ref, entry.orchestratorId))
                  AdaptiveButton(
                    key: const ValueKey('ultra.open-orchestrator'),
                    label: 'Orchestrator',
                    emphasis: ButtonEmphasis.plain,
                    onPressed: () => context.push(Routes.codeSession(entry.orchestratorId)),
                  ),
                if (entry.active)
                  AdaptiveButton(
                    key: const ValueKey('ultra.stop'),
                    label: 'Stop',
                    emphasis: ButtonEmphasis.plain,
                    onPressed: () => ref.read(ultraRunsProvider.notifier).stop(entry.runId),
                  )
                else if (entry.resumable)
                  AdaptiveButton(
                    key: const ValueKey('ultra.resume'),
                    label: 'Resume',
                    emphasis: ButtonEmphasis.plain,
                    onPressed: () => _resume(context, ref),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 22),
              child: Text(
                ultraSummaryLine(entry),
                key: const ValueKey('ultra.summary'),
                style: theme.type.caption.copyWith(
                  color: entry.stage == UltraStage.failed ? theme.danger : theme.textMuted,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            if (j != null) ...[
              for (final phase in j.plan.phases) _PhaseView(journal: j, phase: phase, now: now, live: entry.active),
              if (j.steps[criticKey] case final critic?)
                Padding(
                  padding: const EdgeInsets.only(top: 6, left: 22),
                  child: _AgentRow(record: critic, now: now, live: entry.active),
                ),
              if (j.gaps case final gaps?)
                _PhaseView(journal: j, phase: gaps, now: now, live: entry.active, extra: true),
            ],
            if (entry.answer.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8, left: 22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ChatMarkdown(entry.answer),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: AdaptiveButton(
                        key: const ValueKey('ultra.handoff'),
                        label: 'Hand to this session’s agent',
                        emphasis: ButtonEmphasis.secondary,
                        onPressed: () =>
                            ref.read(codeSessionProvider(entry.sessionId).notifier).send(ultraHandoff(entry)),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _resume(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(ultraRunsProvider.notifier).resume(entry.runId);
    } on UltraError catch (e) {
      if (context.mounted) showAdaptiveToast(context, e.message);
    }
  }

  static bool _exists(WidgetRef ref, String id) =>
      ref.watch(codeSessionsProvider.select((all) => all.any((s) => s.id == id)));
}

/// The run's one-line status: stage, then agents, spend and time against the caps.
String ultraSummaryLine(UltraRunEntry e) {
  final j = e.journal;
  final stage = switch (e.stage) {
    UltraStage.planning => 'Planning',
    UltraStage.running => 'Running',
    UltraStage.synthesizing => 'Writing up',
    UltraStage.done => switch (j?.status) {
      UltraRunStatus.capped => 'Hit a cap',
      UltraRunStatus.stopped => 'Stopped',
      _ => 'Done',
    },
    UltraStage.failed => 'Stopped',
  };
  final parts = [
    stage,
    if (j != null) ...[
      '${j.agentsStarted} of ${j.limits.maxAgents} agents',
      '${formatMicros(_spent(j))} of ${formatMicros(j.budgetMicros > 0 ? j.budgetMicros : j.limits.budgetMicros)}',
      '${formatUltraDuration(j.elapsed)} of ${formatUltraDuration(j.limits.wallTime)}',
    ],
  ];
  final why = e.error.isNotEmpty ? e.error : (j?.note ?? '');
  return [parts.join(' · '), if (why.isNotEmpty && !e.active) why].join(' — ');
}

int _spent(UltraJournal j) => j.steps.values.fold(0, (n, s) => n + s.shownCostMicros);

String _firstLine(String s) => s.trim().split('\n').first;

/// A phase: its title and progress, then its agents. Open while it has work
/// going or waiting; folded once every step is over.
class _PhaseView extends StatefulWidget {
  const _PhaseView({
    required this.journal,
    required this.phase,
    required this.now,
    required this.live,
    this.extra = false,
  });

  /// The run is going (a running step isn't one a quit cut off).
  final bool live;

  final UltraJournal journal;
  final UltraPhase phase;
  final DateTime now;

  /// The critic's gap phase.
  final bool extra;

  @override
  State<_PhaseView> createState() => _PhaseViewState();
}

class _PhaseViewState extends State<_PhaseView> {
  bool? _open;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final p = widget.phase;
    final records = [
      for (final r in widget.journal.steps.values)
        if (r.phaseId == p.id) r,
    ];
    final expected = (p.forEach.isEmpty ? 1 : p.forEach.length) * p.steps.length;
    final finished = records.where((r) => r.status.over).length;
    final waiting = (expected - records.length).clamp(0, expected);
    final allOver = records.isNotEmpty && waiting == 0 && finished == records.length;
    final open = _open ?? !allOver;
    final label = [
      if (widget.extra) 'Gaps: ${p.title}' else p.title,
      p.fanOut == FanOut.pipeline ? 'pipeline' : 'parallel',
      '$finished/$expected done',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _open = !open),
              child: Semantics(
                button: true,
                expanded: open,
                child: Row(
                  children: [
                    AnimatedRotation(
                      turns: open ? 0 : -0.25,
                      duration: const Duration(milliseconds: 150),
                      child: AdaptiveIcon(EveryIcon.chevronDown, size: 12, color: theme.textMuted),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.type.callout.medium.tint(theme.text),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (open) ...[
            for (final r in records)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 16),
                child: _AgentRow(key: ValueKey('ultra.step.${r.key}'), record: r, now: widget.now, live: widget.live),
              ),
            if (waiting > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 16),
                child: Text('$waiting waiting', style: theme.type.caption.tint(theme.textMuted)),
              ),
          ],
        ],
      ),
    );
  }
}

/// One step's agent: status, title, cost, time, and Open for its latest child.
class _AgentRow extends ConsumerWidget {
  const _AgentRow({super.key, required this.record, required this.now, required this.live});

  final StepRecord record;
  final DateTime now;
  final bool live;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final r = record;
    final child = r.childIds.lastOrNull;
    final exists = child != null && ref.watch(codeSessionsProvider.select((all) => all.any((s) => s.id == child)));
    final cutOff = !live && r.status == StepStatus.running;
    final color = switch (r.status) {
      StepStatus.done => r.verified == false || r.merge?.merged == false ? theme.warning : theme.success,
      StepStatus.running => cutOff ? theme.textMuted : theme.accent,
      StepStatus.failed || StepStatus.stopped => theme.danger,
      StepStatus.pending || StepStatus.skipped => theme.textMuted,
    };
    final elapsed = cutOff ? null : r.elapsedAt(now);
    final meta = [
      if (cutOff) 'Cut off' else ultraStepStatusLabel(r),
      if (r.attempts > 1) 'try ${r.attempts}',
      if (r.shownCostMicros > 0) formatMicros(r.shownCostMicros),
      ?(elapsed == null ? null : formatUltraDuration(elapsed)),
    ].join(' · ');
    final title = r.item == null ? r.title : '${r.title}: ${r.item}';
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
      decoration: BoxDecoration(
        border: Border.all(color: theme.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.type.callout.tint(theme.text),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                meta,
                style: theme.type.caption.copyWith(
                  color: theme.textMuted,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              if (exists)
                AdaptiveButton(
                  key: ValueKey('ultra.open.${r.key}'),
                  label: 'Open',
                  emphasis: ButtonEmphasis.plain,
                  onPressed: () => context.push(Routes.codeSession(child)),
                ),
            ],
          ),
          if (r.note.isNotEmpty && r.status != StepStatus.running)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 15),
              child: Text(
                r.note,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.type.caption.tint(theme.textMuted),
              ),
            ),
          if (r.merge case MergeOutcome(merged: false, :final branch))
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 15),
              child: Text('Not merged: left on $branch', style: theme.type.caption.tint(theme.warning)),
            ),
        ],
      ),
    );
  }
}

/// A step's status in words.
String ultraStepStatusLabel(StepRecord r) => switch (r.status) {
  StepStatus.pending => 'Waiting',
  StepStatus.running => r.verified == false ? 'Redoing' : 'Working',
  StepStatus.done => r.verified == false ? 'Done, check failed' : (r.verified == true ? 'Done, checked' : 'Done'),
  StepStatus.failed => 'Failed',
  StepStatus.skipped => 'Skipped',
  StepStatus.stopped => 'Stopped',
};

/// Rebuilds every second while [active], so running times count up.
class _Ticker extends StatefulWidget {
  const _Ticker({required this.active, required this.builder});

  final bool active;
  final Widget Function(BuildContext context, DateTime now) builder;

  @override
  State<_Ticker> createState() => _TickerState();
}

class _TickerState extends State<_Ticker> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_Ticker old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.active && _timer == null) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    } else if (!widget.active) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, DateTime.now());
}
