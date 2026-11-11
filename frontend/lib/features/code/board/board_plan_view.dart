import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/motion/ambient.dart';
import '../../../core/motion/motion.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../../../core/ui/glass.dart';
import '../../usage/usage_totals.dart';
import '../code_providers.dart';
import '../domain/agent_mode.dart';
import '../domain/code_session.dart';
import '../ui/console/git_button.dart' show mergeLocally;
import '../ui/harness_logo.dart';
import 'board_limits.dart' show boardCostLine;
import 'board_plan.dart';
import 'board_plan_providers.dart';
import 'board_planner.dart';
import 'board_race.dart';
import 'board_state.dart';

// The Board's Plan lane: goals split into tasks and delegated, and races. Data and rules in board_plan.dart and
// board_race.dart, their notifiers in board_plan_providers.dart.

/// What the Board says a session is doing, in a word.
String phaseWord(BoardPhase p) => switch (p) {
  BoardPhase.needsYou => 'Needs you',
  BoardPhase.working => 'Working',
  BoardPhase.waitingOnWork => 'Waiting on its work',
  BoardPhase.paused => 'Paused',
  BoardPhase.failed => 'Failed',
  BoardPhase.doneUnseen || BoardPhase.doneSeen => 'Done',
};

String _leadText(String label, String model) => model.isEmpty ? label : '$label · $model';

/// Keeps a race's Keep: the winner's work merged (the session's own merge, with its confirms), the losers' worktrees
/// removed. Tests replace it.
abstract interface class RaceActions {
  /// True when the winner's work landed (false when the user said no, or the agent was asked to tidy its branch).
  Future<bool> merge(BuildContext context, WidgetRef ref, CodeSessionInfo winner);
  Future<void> discard(WidgetRef ref, CodeSessionInfo loser);
}

final boardRaceActionsProvider = Provider<RaceActions>((ref) => const _AppRaceActions());

final class _AppRaceActions implements RaceActions {
  const _AppRaceActions();

  @override
  Future<bool> merge(BuildContext context, WidgetRef ref, CodeSessionInfo winner) => mergeLocally(context, ref, winner);

  @override
  Future<void> discard(WidgetRef ref, CodeSessionInfo loser) => loser.worktree != null
      ? ref.read(codeGitProvider(loser.id).notifier).discard()
      : ref.read(codeSessionsProvider.notifier).remove(loser.id);
}

/// The Plan lane: goals (newest first), then races. [phases] are the Board's phases of the sessions the tasks and
/// runners started; [taskKey] gives each task card the key a delegated task's session card flies out from.
class PlanLane extends ConsumerStatefulWidget {
  const PlanLane({
    super.key,
    required this.phases,
    required this.taskKey,
    required this.onInspect,
    required this.scrolls,
    this.onCollapse,
  });

  final Map<String, BoardPhase> phases;
  final GlobalKey Function(String taskId) taskKey;
  final ValueChanged<String> onInspect;

  /// Fills its height and scrolls (the wide Board); else as tall as its cards (the narrow one).
  final bool scrolls;
  final VoidCallback? onCollapse;

  @override
  ConsumerState<PlanLane> createState() => _PlanLaneState();
}

/// A Keep in flight from the lane (one at a time; a second click meanwhile does nothing).
enum _Keep { idle, keeping }

class _PlanLaneState extends ConsumerState<PlanLane> {
  var _keep = _Keep.idle;

  void _newGoal() {
    final projects = ref.read(codeProjectsProvider);
    if (projects.isEmpty) {
      showAdaptiveToast(context, 'Open a project in Code first.');
      return;
    }
    ref.read(boardPlansProvider.notifier).add(projectId: projects.first.id, planner: ref.read(defaultLeadProvider));
  }

  Future<void> _race({String? projectId, String prompt = '', String? goalId}) =>
      startRace(context, ref, projectId: projectId, prompt: prompt, goalId: goalId);

  Future<void> _compare(BoardRace race) async {
    final keep = await showKitDialog<String>(context, builder: (context) => CompareView(raceId: race.id));
    if (keep == null || !mounted) return;
    await keepRunner(race.id, keep);
  }

  /// Keeps [session]'s runner of [raceId] once the user agrees: the winner's own merge runs first (asking the agent
  /// to tidy its branch first when it needs to), and only once its work has landed are the other runners stopped and
  /// removed with their worktrees. A merge that didn't happen loses nothing.
  Future<void> keepRunner(String raceId, String session) async {
    if (_keep != _Keep.idle) return;
    final races = ref.read(boardRacesProvider.notifier);
    if (races.keepBlocked(raceId) case final why?) {
      showAdaptiveToast(context, why);
      return;
    }
    final race = races.race(raceId)!;
    final sessions = ref.read(codeSessionsProvider);
    final winner = sessions.where((s) => s.id == session).firstOrNull;
    if (winner == null) return;
    final working = {
      for (final r in race.runners)
        if (r.run case RunnerRunning(:final sessionId)) sessionId,
    };
    final losers = [
      for (final r in race.runners)
        if (sessionOfRunner(r.run) case final id? when id != session) ?sessions.where((s) => s.id == id).firstOrNull,
    ];
    final leads = {for (final l in ref.read(plannerLeadsProvider)) l.id: l.label};
    String name(CodeSessionInfo s) =>
        '${_leadText(leads[s.harness] ?? s.harness, s.model)}${working.contains(s.id) ? ' (still working)' : ''}';
    final ok = await showAdaptiveConfirm(
      context,
      title: 'Keep this one?',
      message: [
        '"${winner.title}" on ${_leadText(leads[winner.harness] ?? winner.harness, winner.model)} merges first (you '
            'confirm the merge).',
        if (losers.isNotEmpty)
          'Once it has merged, these are stopped and removed with their worktrees and branches: '
              '${losers.map(name).join(', ')}.',
      ].join(' '),
      confirmLabel: 'Keep',
    );
    if (!ok || !mounted) return;
    setState(() => _keep = _Keep.keeping);
    try {
      final actions = ref.read(boardRaceActionsProvider);
      final merged = await actions.merge(context, ref, winner);
      if (!mounted) return;
      if (!merged) {
        showAdaptiveToast(context, 'Nothing merged yet, so the other runners are kept.');
        return;
      }
      races.keep(raceId, session);
      final starter = ref.read(boardStarterProvider);
      for (final l in losers) {
        try {
          if (working.contains(l.id)) await starter.stop(l.id);
          await actions.discard(ref, l);
        } on Object catch (e) {
          if (mounted) showAdaptiveToast(context, "Couldn't remove ${l.title}: $e");
        }
      }
    } finally {
      if (mounted) setState(() => _keep = _Keep.idle);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final goals = ref.watch(boardPlansProvider);
    final races = ref.watch(boardRacesProvider);
    final head = Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 0, 8),
      child: SizedBox(
        height: 28,
        child: Row(
          children: [
            AdaptiveIcon(EveryIcon.workflow, size: 14, color: theme.textMuted),
            const SizedBox(width: 8),
            Text('Plan', style: theme.type.callout.semibold.tint(theme.text)),
            const SizedBox(width: 8),
            TickingCount(planCount(goals, races.length), style: theme.type.caption.mono.tint(theme.textSubtle)),
            const Spacer(),
            KitIconButton(
              key: const ValueKey('board.plan.race'),
              icon: EveryIcon.activity,
              tooltip: 'Race',
              size: 15,
              onPressed: _race,
            ),
            KitIconButton(
              key: const ValueKey('board.plan.new'),
              icon: EveryIcon.add,
              tooltip: 'New goal',
              size: 15,
              onPressed: _newGoal,
            ),
            if (widget.onCollapse case final collapse?)
              KitIconButton(
                key: const ValueKey('board.plan.collapse'),
                icon: EveryIcon.chevronLeft,
                tooltip: 'Hide the plan',
                size: 15,
                onPressed: collapse,
              ),
          ],
        ),
      ),
    );
    final cards = <Widget>[
      if (goals.isEmpty && races.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
          child: Text(
            'Write a goal and split it into tasks to delegate, or race one prompt on a few agents.',
            style: theme.type.caption.tint(theme.textSubtle),
          ),
        ),
      for (final (i, g) in goals.indexed)
        Padding(
          key: ValueKey('board.goal.${g.id}'),
          padding: const EdgeInsets.only(bottom: 8),
          child: GoalCard(
            goal: g,
            phases: widget.phases,
            taskKey: widget.taskKey,
            onInspect: widget.onInspect,
            onRace: () => _race(projectId: g.projectId, prompt: g.text, goalId: g.id),
          ).rowIn(i),
        ),
      for (final r in races)
        Padding(
          key: ValueKey('board.race.${r.id}'),
          padding: const EdgeInsets.only(bottom: 8),
          child: RaceCard(
            race: r,
            phases: widget.phases,
            onInspect: widget.onInspect,
            onCompare: () => _compare(r),
            keeping: _keep == _Keep.keeping,
          ).settle(),
        ),
    ];
    if (!widget.scrolls) {
      return Column(
        key: const ValueKey('board.column.plan'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [head, ...cards],
      );
    }
    return Column(
      key: const ValueKey('board.column.plan'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        head,
        Expanded(
          child: ListView(primary: false, padding: const EdgeInsets.only(bottom: 16), children: cards),
        ),
      ],
    );
  }
}

/// A goal's text cut to a chip: its first line, at most 40 characters.
String goalLabel(PlanGoal g) {
  final line = g.text.trim().split('\n').first.trim();
  return line.length <= 40 ? line : '${line.substring(0, 39)}…';
}

/// The goal a session works for, under its title on the Board.
class GoalChip extends StatelessWidget {
  const GoalChip(this.label, {super.key});
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(color: theme.accent.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(99)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AdaptiveIcon(EveryIcon.workflow, size: 10, color: theme.accentText),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.type.micro.tint(theme.accentText),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The collapsed Plan lane: a slim rail with the count and a way back.
class PlanRail extends ConsumerWidget {
  const PlanRail({super.key, required this.onExpand});
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final n = ref.watch(boardPlansProvider).length + ref.watch(boardRacesProvider).length;
    return Column(
      key: const ValueKey('board.plan.rail'),
      children: [
        KitIconButton(icon: EveryIcon.chevronRight, tooltip: 'Show the plan', size: 15, onPressed: onExpand),
        const SizedBox(height: 6),
        AdaptiveIcon(EveryIcon.workflow, size: 14, color: theme.textMuted),
        const SizedBox(height: 6),
        TickingCount(n, style: theme.type.caption.mono.tint(theme.textSubtle)),
      ],
    );
  }
}

/// A thin bar of [fraction], easing to it ([Motion] off: it jumps).
class _ThinBar extends StatelessWidget {
  const _ThinBar({required this.fraction, required this.color});
  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(99),
      child: SizedBox(
        height: 3,
        child: Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: theme.border)),
            Positioned.fill(
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: fraction.clamp(0, 1)),
                duration: Motion.reduced(context) ? Duration.zero : Motion.move,
                curve: Motion.easeOut,
                builder: (context, v, _) => FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: v,
                  heightFactor: 1,
                  child: ColoredBox(color: color),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The menu of leads ([PlannerLead]s with each model, or their default): picks one into [onPick]. [why] greys a lead
/// out with its reason (the planner of a harness that can't plan headless).
List<MenuAction> leadActions(
  BuildContext context,
  List<PlannerLead> leads, {
  required LeadPick current,
  required ValueChanged<LeadPick> onPick,
  String? Function(LeadPick pick)? why,
}) => [
  for (final l in leads)
    for (final model in ['', ...l.models])
      () {
        final pick = (harness: l.id, model: model);
        final no = why?.call(pick);
        return MenuAction(
          label: '${_leadText(l.label, model.isEmpty ? 'default' : model)}${no == null ? '' : ' — $no'}',
          checked: pick == current,
          onSelected: () => no == null ? onPick(pick) : showAdaptiveToast(context, no),
        );
      }(),
];

/// A goal on the Plan lane: written, split by its planner, its tasks edited and delegated, its progress.
class GoalCard extends ConsumerStatefulWidget {
  const GoalCard({
    super.key,
    required this.goal,
    required this.phases,
    required this.taskKey,
    required this.onInspect,
    required this.onRace,
  });

  final PlanGoal goal;
  final Map<String, BoardPhase> phases;
  final GlobalKey Function(String taskId) taskKey;
  final ValueChanged<String> onInspect;
  final VoidCallback onRace;

  @override
  ConsumerState<GoalCard> createState() => _GoalCardState();
}

class _GoalCardState extends ConsumerState<GoalCard> {
  late final _text = TextEditingController(text: widget.goal.text);

  /// The task cards' centres in the list, for the dependency lines (measured after layout).
  var _centres = const <String, double>{};
  final _list = GlobalKey();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  BoardPlans get _plans => ref.read(boardPlansProvider.notifier);

  void _measure() {
    if (!mounted) return;
    final box = _list.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return;
    final next = <String, double>{};
    for (final t in widget.goal.tasks) {
      final b = widget.taskKey(t.id).currentContext?.findRenderObject() as RenderBox?;
      if (b == null || !b.attached || !b.hasSize) continue;
      next[t.id] = box.globalToLocal(b.localToGlobal(Offset(0, b.size.height / 2))).dy;
    }
    final same = next.length == _centres.length && next.entries.every((e) => (_centres[e.key] ?? -1) == e.value);
    if (!same) setState(() => _centres = next);
  }

  void _delegate({String? taskId}) {
    if (_plans.delegate(widget.goal.id, taskId: taskId) case final why?) showAdaptiveToast(context, why);
  }

  int get _startedCount => widget.goal.tasks.where((t) => t.run is TaskStarted || t.run is TaskStarting).length;

  Future<void> _cancel() async {
    final g = widget.goal;
    final started = _startedCount;
    var choice = StartedChoice.keepRunning;
    if (started > 0) {
      final picked = await askStartedChoice(
        context,
        title: 'Cancel this plan?',
        body:
            'Tasks not started yet are cancelled. $started started ${started == 1 ? 'task is' : 'tasks are'} still '
            'running.',
        keyPrefix: 'board.goal.cancel',
      );
      if (picked == null || !mounted) return;
      choice = picked;
    }
    _plans.cancel(g.id, started: choice);
  }

  Future<void> _remove() async {
    final g = widget.goal;
    final started = _startedCount;
    var choice = StartedChoice.keepRunning;
    if (started > 0) {
      final picked = await askStartedChoice(
        context,
        title: 'Remove this goal?',
        body:
            'Tasks not started yet never start. $started started ${started == 1 ? 'task is' : 'tasks are'} still '
            'running.',
        keyPrefix: 'board.goal.removing',
      );
      if (picked == null || !mounted) return;
      choice = picked;
    } else if (_plans.busy(g.id)) {
      final ok = await showAdaptiveConfirm(
        context,
        title: 'Remove this goal?',
        message: g.stage == GoalStage.splitting
            ? 'Its planner is still splitting it; that stops.'
            : 'Its queued tasks never start.',
        confirmLabel: 'Remove',
        destructive: true,
      );
      if (!ok || !mounted) return;
    }
    _plans.remove(g.id, started: choice);
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final g = widget.goal;
    final leads = ref.watch(plannerLeadsProvider);
    final labels = {for (final l in leads) l.id: l.label};
    final projects = ref.watch(codeProjectsProvider);
    final project = projects.where((p) => p.id == g.projectId).firstOrNull;
    final planner = ref.read(boardPlannerProvider);
    final writing = g.stage == GoalStage.draft || g.stage == GoalStage.splitting;
    final splitting = g.stage == GoalStage.splitting;
    if (!writing) WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    final stageText = switch (g.stage) {
      GoalStage.draft => 'Goal',
      GoalStage.splitting => 'Splitting',
      GoalStage.ready => '${g.tasks.length} tasks',
      GoalStage.running => 'Running',
      GoalStage.done => 'Done',
      GoalStage.failed => 'Stuck',
      GoalStage.cancelled => 'Cancelled',
    };
    final progress = g.progress;
    final drafts = g.tasks.any((t) => t.run is TaskDraft) && g.stage != GoalStage.cancelled;

    final header = Row(
      children: [
        AdaptiveIcon(EveryIcon.workflow, size: 13, color: theme.accentText),
        const SizedBox(width: 6),
        Text(stageText, style: theme.type.caption.medium.tint(theme.textMuted)),
        const Spacer(),
        AdaptiveMenuButton(
          key: ValueKey('board.goal.planner.${g.id}'),
          tooltip: 'Planner',
          actions: leadActions(
            context,
            leads,
            current: g.planner,
            onPick: (p) => _plans.setPlanner(g.id, p),
            why: planner.unavailable,
          ),
          child: QuietTrigger(
            leading: HarnessLogo(g.planner.harness, size: 14),
            label: _leadText(labels[g.planner.harness] ?? g.planner.harness, g.planner.model),
            enabled: writing,
          ),
        ),
        KitIconButton(
          key: ValueKey('board.goal.remove.${g.id}'),
          icon: EveryIcon.close,
          tooltip: 'Remove goal',
          size: 13,
          onPressed: _remove,
        ),
      ],
    );

    final Widget body;
    if (writing) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AdaptiveTextField(
            key: ValueKey('board.goal.text.${g.id}'),
            controller: _text,
            placeholder: 'What should get done?',
            minLines: 2,
            maxLines: 6,
            onChanged: (v) => _plans.setText(g.id, v),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              AdaptiveMenuButton(
                tooltip: 'Project',
                actions: [
                  for (final p in projects)
                    MenuAction(
                      label: p.name,
                      checked: p.id == g.projectId,
                      onSelected: () => _plans.setProject(g.id, p.id),
                    ),
                ],
                child: MenuTrigger(project?.name ?? 'Pick a project', muted: true),
              ),
              const Spacer(),
              KitButton(
                key: ValueKey('board.goal.race.${g.id}'),
                label: 'Race',
                style: KitButtonStyle.ghost,
                onPressed: splitting || g.text.trim().isEmpty ? null : widget.onRace,
              ),
              const SizedBox(width: 6),
              KitButton(
                key: ValueKey('board.goal.split.${g.id}'),
                label: 'Split',
                busy: splitting,
                onPressed: splitting || g.text.trim().isEmpty ? null : () => unawaited(_plans.split(g.id)),
              ),
            ],
          ),
          if (splitting)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ShimmerText(
                'Asking ${labels[g.planner.harness] ?? g.planner.harness} for tasks…',
                style: theme.type.caption,
              ),
            ),
          if (g.error case final why? when !splitting)
            Padding(
              key: ValueKey('board.goal.error.${g.id}'),
              padding: const EdgeInsets.only(top: 8),
              child: Text(why, style: theme.type.caption.tint(theme.danger)),
            ),
        ],
      );
    } else {
      final edges = [
        for (final t in g.tasks)
          for (final a in t.after)
            if (_centres[a] != null && _centres[t.id] != null) (from: _centres[a]!, to: _centres[t.id]!),
      ];
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(g.text.trim(), maxLines: 3, overflow: TextOverflow.ellipsis, style: theme.type.callout.tint(theme.text)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _ThinBar(
                  fraction: progress.total == 0 ? 0 : progress.done / progress.total,
                  color: g.stage == GoalStage.failed ? theme.warning : theme.accent,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${progress.done} of ${progress.total}',
                key: ValueKey('board.goal.progress.${g.id}'),
                style: theme.type.caption.mono.tint(theme.textSubtle),
              ),
            ],
          ),
          const SizedBox(height: 10),
          CustomPaint(
            key: _list,
            painter: _DependencyLines(edges: edges, color: theme.textSubtle),
            child: Padding(
              padding: const EdgeInsets.only(left: 14),
              child: ReorderableList(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: g.tasks.length,
                // The index after the move; [reorderTasks] takes the slot before it.
                onReorderItem: (from, to) => _plans.reorder(g.id, from, to > from ? to + 1 : to),
                itemBuilder: (context, i) {
                  final t = g.tasks[i];
                  return Padding(
                    key: ValueKey('board.task.slot.${t.id}'),
                    padding: const EdgeInsets.only(bottom: 6),
                    child: TaskCard(
                      key: widget.taskKey(t.id),
                      goal: g,
                      task: t,
                      index: i,
                      leads: leads,
                      phase: switch (sessionOfRun(t.run)) {
                        final s? => widget.phases[s],
                        null => null,
                      },
                      onDelegate: () => _delegate(taskId: t.id),
                      onInspect: widget.onInspect,
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            alignment: WrapAlignment.end,
            children: [
              if (g.stage != GoalStage.cancelled)
                KitButton(
                  key: ValueKey('board.goal.add.${g.id}'),
                  label: 'Add task',
                  style: KitButtonStyle.ghost,
                  icon: EveryIcon.add,
                  onPressed: () => _plans.addTask(g.id),
                ),
              KitButton(
                key: ValueKey('board.goal.race.${g.id}'),
                label: 'Race',
                style: KitButtonStyle.ghost,
                onPressed: widget.onRace,
              ),
              if (g.stage == GoalStage.running)
                KitButton(
                  key: ValueKey('board.goal.cancel.${g.id}'),
                  label: 'Cancel',
                  style: KitButtonStyle.danger,
                  onPressed: _cancel,
                ),
              if (drafts)
                AdaptiveMenuButton(
                  key: ValueKey('board.goal.mode.${g.id}'),
                  tooltip: 'Delegated tasks start in',
                  actions: [
                    for (final m in const [AgentMode.ask, AgentMode.autoEdit, AgentMode.auto, AgentMode.fullAuto])
                      MenuAction(label: m.label, checked: g.mode == m.name, onSelected: () => _plans.setMode(g.id, m)),
                  ],
                  child: QuietTrigger(
                    label: 'In ${(AgentMode.values.asNameMap()[g.mode] ?? AgentMode.autoEdit).label}',
                  ),
                ),
              if (drafts)
                KitButton(
                  key: ValueKey('board.goal.delegate.${g.id}'),
                  label: 'Delegate all',
                  icon: EveryIcon.play,
                  onPressed: _delegate,
                ),
            ],
          ),
        ],
      );
    }

    return GlowPulse(
      active: g.stage == GoalStage.running,
      color: theme.accent,
      strength: 0.6,
      radius: EveryTheme.cardRadius,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: glassDecoration(
          theme,
          edge: g.stage == GoalStage.failed ? theme.warning : null,
          radius: EveryTheme.cardRadius,
        ),
        child: AnimatedSize(
          duration: Motion.reduced(context) ? Duration.zero : Motion.move,
          curve: Motion.easeInOut,
          alignment: Alignment.topCenter,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [header, const SizedBox(height: 8), body],
          ),
        ),
      ),
    );
  }
}

/// Thin curves in the task list's left gutter from each task to the ones waiting on it.
class _DependencyLines extends CustomPainter {
  _DependencyLines({required this.edges, required this.color});

  final List<({double from, double to})> edges;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.45)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1;
    final dot = Paint()..color = color.withValues(alpha: 0.6);
    for (final e in edges) {
      // Further apart, further out: lines between distant tasks don't sit on the short ones.
      final bulge = (2 + (e.to - e.from).abs() / 40).clamp(2.0, 10.0);
      final path = Path()
        ..moveTo(12, e.from)
        ..cubicTo(12 - bulge, e.from, 12 - bulge, e.to, 12, e.to);
      canvas.drawPath(path, paint);
      canvas.drawCircle(Offset(12, e.to), 1.8, dot);
    }
  }

  @override
  bool shouldRepaint(_DependencyLines old) =>
      old.color != color ||
      old.edges.length != edges.length ||
      [for (var i = 0; i < edges.length; i++) old.edges[i] != edges[i]].any((d) => d);
}

/// One task of a goal: editable while a draft (title, brief, what it waits for, its lead, its own branch), then its
/// session's state.
class TaskCard extends ConsumerStatefulWidget {
  const TaskCard({
    super.key,
    required this.goal,
    required this.task,
    required this.index,
    required this.leads,
    required this.phase,
    required this.onDelegate,
    required this.onInspect,
  });

  final PlanGoal goal;
  final GoalTask task;
  final int index;
  final List<PlannerLead> leads;

  /// Its session's phase on the Board, once started.
  final BoardPhase? phase;
  final VoidCallback onDelegate;
  final ValueChanged<String> onInspect;

  @override
  ConsumerState<TaskCard> createState() => _TaskCardState();
}

class _TaskCardState extends ConsumerState<TaskCard> {
  late final _title = TextEditingController(text: widget.task.title);
  late final _brief = TextEditingController(text: widget.task.brief);

  @override
  void didUpdateWidget(TaskCard old) {
    super.didUpdateWidget(old);
    // A new split or another edit path changed it: show that (never while the user is typing the same text).
    if (widget.task.title != _title.text && widget.task.title != old.task.title) _title.text = widget.task.title;
    if (widget.task.brief != _brief.text && widget.task.brief != old.task.brief) _brief.text = widget.task.brief;
  }

  @override
  void dispose() {
    _title.dispose();
    _brief.dispose();
    super.dispose();
  }

  BoardPlans get _plans => ref.read(boardPlansProvider.notifier);

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final g = widget.goal;
    final t = widget.task;
    final labels = {for (final l in widget.leads) l.id: l.label};
    final number = {for (final (i, x) in g.tasks.indexed) x.id: i + 1};
    final editable = t.run.editable;
    final waitsOn = [for (final a in t.after) '${number[a] ?? '?'}'];

    final (String state, DotStatus dot, Color tint) = switch (t.run) {
      TaskDraft() => ('Draft', DotStatus.idle, theme.textSubtle),
      TaskQueued() when taskBlocked(g, t) => (
        'Blocked: a task it waits for didn\'t finish',
        DotStatus.failed,
        theme.warning,
      ),
      TaskQueued() => ('Waiting on ${waitsOn.join(', ')}', DotStatus.idle, theme.textMuted),
      TaskStarting() => ('Starting…', DotStatus.running, theme.textMuted),
      TaskStarted() => (
        widget.phase == null ? 'Started' : phaseWord(widget.phase!),
        switch (widget.phase) {
          BoardPhase.needsYou => DotStatus.waiting,
          BoardPhase.failed => DotStatus.failed,
          BoardPhase.doneSeen || BoardPhase.doneUnseen => DotStatus.done,
          _ => DotStatus.running,
        },
        widget.phase == BoardPhase.needsYou ? theme.accentText : theme.textMuted,
      ),
      TaskDone() => ('Done', DotStatus.done, theme.textMuted),
      TaskFailed(:final why) => (why, DotStatus.failed, theme.danger),
      TaskCancelled() => ('Cancelled', DotStatus.idle, theme.textSubtle),
    };
    final session = sessionOfRun(t.run);

    final leadChip = AdaptiveMenuButton(
      key: ValueKey('board.task.lead.${t.id}'),
      tooltip: 'Runs on',
      actions: leadActions(
        context,
        widget.leads,
        current: t.lead,
        onPick: (p) => _plans.editTask(g.id, t.id, lead: p),
      ),
      child: QuietTrigger(
        leading: HarnessLogo(t.lead.harness, size: 13),
        label: _leadText(labels[t.lead.harness] ?? t.lead.harness, t.lead.model),
        enabled: editable,
      ),
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 6, 8),
      decoration: BoxDecoration(
        color: theme.text.withValues(alpha: 0.03),
        border: Border.all(color: theme.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (editable)
                ReorderableDragStartListener(
                  index: widget.index,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.grab,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: AdaptiveIcon(EveryIcon.menu, size: 12, color: theme.textSubtle),
                    ),
                  ),
                ),
              Text('${widget.index + 1}', style: theme.type.caption.mono.tint(theme.textSubtle)),
              const SizedBox(width: 8),
              Expanded(
                child: editable
                    ? AdaptiveTextField(
                        key: ValueKey('board.task.title.${t.id}'),
                        controller: _title,
                        borderless: true,
                        placeholder: 'Title',
                        onChanged: (v) => _plans.editTask(g.id, t.id, title: v),
                      )
                    : Text(
                        t.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.type.callout.medium.tint(theme.text),
                      ),
              ),
              if (editable)
                KitIconButton(
                  key: ValueKey('board.task.remove.${t.id}'),
                  icon: EveryIcon.close,
                  tooltip: 'Remove task',
                  size: 12,
                  onPressed: () => _plans.removeTask(g.id, t.id),
                ),
            ],
          ),
          if (editable) ...[
            AdaptiveTextField(
              key: ValueKey('board.task.brief.${t.id}'),
              controller: _brief,
              borderless: true,
              placeholder: 'What to do and how to check it',
              minLines: 1,
              maxLines: 4,
              onChanged: (v) => _plans.editTask(g.id, t.id, brief: v),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                leadChip,
                AdaptiveMenuButton(
                  key: ValueKey('board.task.after.${t.id}'),
                  tooltip: 'Waits for',
                  actions: [
                    for (final x in g.tasks)
                      if (x.id != t.id)
                        MenuAction(
                          label: '${number[x.id]}  ${x.title}',
                          checked: t.after.contains(x.id),
                          onSelected: () {
                            final next = t.after.contains(x.id)
                                ? [...t.after.where((a) => a != x.id)]
                                : [...t.after, x.id];
                            if (!_plans.setAfter(g.id, t.id, next)) {
                              showAdaptiveToast(context, 'That would make the tasks wait on each other in a loop.');
                            }
                          },
                        ),
                  ],
                  child: QuietTrigger(label: waitsOn.isEmpty ? 'No dependencies' : 'After ${waitsOn.join(', ')}'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                KitSwitch(
                  key: ValueKey('board.task.worktree.${t.id}'),
                  value: t.worktree,
                  semanticLabel: 'Own branch',
                  onChanged: (v) => _plans.editTask(g.id, t.id, worktree: v),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    'Own branch',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.type.caption.tint(theme.textSubtle),
                  ),
                ),
                const Spacer(),
                KitButton(
                  key: ValueKey('board.task.delegate.${t.id}'),
                  label: 'Delegate',
                  style: KitButtonStyle.soft,
                  onPressed: widget.onDelegate,
                ),
              ],
            ),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  StatusDot(dot),
                  const SizedBox(width: 6),
                  HarnessLogo(t.lead.harness, size: 13),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      state,
                      key: ValueKey('board.task.state.${t.id}'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.type.caption.tint(tint),
                    ),
                  ),
                  if (t.run is TaskFailed && g.stage != GoalStage.cancelled)
                    KitButton(
                      key: ValueKey('board.task.retry.${t.id}'),
                      label: 'Retry',
                      style: KitButtonStyle.soft,
                      onPressed: () => _plans.retry(g.id, t.id),
                    ),
                  if (session != null && ref.watch(codeSessionsProvider).any((s) => s.id == session))
                    KitButton(
                      key: ValueKey('board.task.open.${t.id}'),
                      label: 'Open',
                      style: KitButtonStyle.ghost,
                      onPressed: () => widget.onInspect(session),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A race: its runners side by side, live while they work; Compare once any is done.
class RaceCard extends ConsumerWidget {
  const RaceCard({
    super.key,
    required this.race,
    required this.phases,
    required this.onInspect,
    required this.onCompare,
    required this.keeping,
  });

  final BoardRace race;
  final Map<String, BoardPhase> phases;
  final ValueChanged<String> onInspect;
  final VoidCallback onCompare;
  final bool keeping;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final labels = {for (final l in ref.watch(plannerLeadsProvider)) l.id: l.label};
    final races = ref.read(boardRacesProvider.notifier);
    final anyDone = race.runners.any((r) => r.run is RunnerDone);
    final stageText = switch (race.stage) {
      RaceStage.starting => 'Starting',
      RaceStage.running => 'Racing',
      RaceStage.comparing => 'Ready to compare',
      RaceStage.kept => 'Kept one',
      RaceStage.cancelled => 'Cancelled',
    };
    final live = race.stage == RaceStage.running || race.stage == RaceStage.starting;
    return GlowPulse(
      active: live,
      color: theme.cyan,
      strength: 0.5,
      radius: EveryTheme.cardRadius,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: glassDecoration(theme, radius: EveryTheme.cardRadius),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                AdaptiveIcon(EveryIcon.activity, size: 13, color: theme.cyan),
                const SizedBox(width: 6),
                Text(stageText, style: theme.type.caption.medium.tint(theme.textMuted)),
                const Spacer(),
                KitIconButton(
                  key: ValueKey('board.race.remove.${race.id}'),
                  icon: EveryIcon.close,
                  tooltip: live ? 'Stop following this race' : 'Remove race',
                  size: 13,
                  onPressed: () async {
                    if (!live) return races.remove(race.id);
                    final choice = await askStartedChoice(
                      context,
                      title: 'Cancel this race?',
                      body:
                          'Its runners can keep running as ordinary sessions, or stop and be removed with their '
                          'worktrees.',
                      keyPrefix: 'board.race.cancel',
                      stopLabel: 'Stop and remove',
                    );
                    if (choice != null) races.cancel(race.id, started: choice);
                  },
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              race.prompt.trim(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.type.callout.tint(theme.text),
            ),
            const SizedBox(height: 10),
            PeriodicRebuild(
              period: const Duration(seconds: 30),
              builder: (context) => Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final (i, r) in race.runners.indexed) ...[
                    if (i > 0) const SizedBox(width: 6),
                    Expanded(
                      child: _RunnerTile(
                        key: ValueKey('board.race.runner.${race.id}.$i'),
                        runner: r,
                        label: _leadText(labels[r.lead.harness] ?? r.lead.harness, r.lead.model),
                        phase: switch (sessionOfRunner(r.run)) {
                          final s? => phases[s],
                          null => null,
                        },
                        kept: race.keptSession != null && sessionOfRunner(r.run) == race.keptSession,
                        onInspect: onInspect,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (race.stage != RaceStage.kept && race.stage != RaceStage.cancelled) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: KitButton(
                  key: ValueKey('board.race.compare.${race.id}'),
                  label: race.stage == RaceStage.comparing ? 'Compare' : 'Compare now',
                  style: race.stage == RaceStage.comparing ? KitButtonStyle.primary : KitButtonStyle.soft,
                  busy: keeping,
                  onPressed: anyDone && !keeping
                      ? () {
                          races.compare(race.id);
                          onCompare();
                        }
                      : null,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RunnerTile extends StatelessWidget {
  const _RunnerTile({
    super.key,
    required this.runner,
    required this.label,
    required this.phase,
    required this.kept,
    required this.onInspect,
  });

  final RaceRunner runner;
  final String label;
  final BoardPhase? phase;
  final bool kept;
  final ValueChanged<String> onInspect;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final started = runner.startedAt;
    String since() => started == null ? '' : ' · ${wallText(DateTime.now().difference(started))}';
    final Widget status = switch (runner.run) {
      RunnerStarting() => ShimmerText('Starting', style: theme.type.caption),
      RunnerRunning() when phase == BoardPhase.needsYou => Text(
        'Needs you${since()}',
        style: theme.type.caption.tint(theme.accentText),
      ),
      // A live shimmer while it runs: where it is in the race.
      RunnerRunning() => ShimmerText(
        '${phase == null ? 'Running' : phaseWord(phase!)}${since()}',
        style: theme.type.caption,
      ),
      RunnerDone(:final at) => Text(
        kept ? 'Kept' : 'Done${started == null ? '' : ' · ${wallText(at.difference(started))}'}',
        style: theme.type.caption.tint(kept ? theme.accentText : theme.textMuted),
      ),
      RunnerFailed(:final why) => Text(why, maxLines: 2, style: theme.type.caption.tint(theme.danger)),
      RunnerDiscarded() => Text('Removed', style: theme.type.caption.tint(theme.textSubtle)),
    };
    final session = sessionOfRunner(runner.run);
    return Pressable(
      onTap: session == null || runner.run is RunnerDiscarded ? null : () => onInspect(session),
      builder: (context, s, child) => AnimatedContainer(
        duration: Motion.press,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: theme.text.withValues(alpha: s.hovered ? 0.06 : 0.03),
          border: Border.all(color: kept ? theme.accent.withValues(alpha: 0.6) : theme.border),
          borderRadius: BorderRadius.circular(10),
        ),
        child: child,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              HarnessLogo(runner.lead.harness, size: 14),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.type.caption.medium.tint(theme.text),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          status,
        ],
      ),
    );
  }
}

/// The Compare view of a race: each runner's diff, tests, cost and time, a preview of its changes, and Keep on
/// finished ones. Pops with the kept runner's session id.
class CompareView extends ConsumerWidget {
  const CompareView({super.key, required this.raceId});
  final String raceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final race = ref.watch(boardRacesProvider).where((r) => r.id == raceId).firstOrNull;
    final labels = {for (final l in ref.watch(plannerLeadsProvider)) l.id: l.label};
    if (race == null) return const SizedBox.shrink();
    final sessions = {for (final s in ref.watch(codeSessionsProvider)) s.id: s};
    return SizedBox(
      width: 900,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text('Compare', style: theme.type.title.semibold.tint(theme.text))),
                KitIconButton(icon: EveryIcon.close, tooltip: 'Close', onPressed: () => Navigator.of(context).pop()),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              race.prompt.trim(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.type.callout.tint(theme.textMuted),
            ),
            const SizedBox(height: 14),
            Flexible(
              child: SingleChildScrollView(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final (i, r) in race.runners.indexed) ...[
                      if (i > 0) const SizedBox(width: 10),
                      Expanded(
                        child: _CompareColumn(
                          key: ValueKey('board.compare.$i'),
                          runner: r,
                          label: _leadText(labels[r.lead.harness] ?? r.lead.harness, r.lead.model),
                          info: switch (sessionOfRunner(r.run)) {
                            final id? => sessions[id],
                            null => null,
                          },
                          canKeep: race.stage != RaceStage.kept && r.run is RunnerDone,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CompareColumn extends ConsumerWidget {
  const _CompareColumn({
    super.key,
    required this.runner,
    required this.label,
    required this.info,
    required this.canKeep,
  });

  final RaceRunner runner;
  final String label;
  final CodeSessionInfo? info;
  final bool canKeep;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final s = info;
    // The diff is read for the comparison (its worktree's git); the transcript and cost only when already open.
    final git = s?.worktree == null ? null : ref.watch(codeGitProvider(s!.id));
    final transcript = s != null && ref.exists(codeSessionProvider(s.id))
        ? ref.watch(codeSessionProvider(s.id).select((st) => st.transcript))
        : null;
    final cost = s != null && ref.exists(codeUsageProvider(s.id))
        ? boardCostLine(ref.watch(codeUsageProvider(s.id)).value ?? const UsageTotals())
        : '';
    final files = git?.value?.files;
    final stats = runnerStats(files: files, transcript: transcript, startedAt: runner.startedAt, run: runner.run);
    Widget fact(String name, String value, {Color? tint}) => Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(child: Text(name, style: theme.type.caption.tint(theme.textSubtle))),
          Text(value, style: theme.type.caption.mono.tint(tint ?? theme.text)),
        ],
      ),
    );
    final first = files?.where((f) => f.hunks.isNotEmpty).firstOrNull;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: glassDecoration(theme, radius: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              HarnessLogo(runner.lead.harness, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.type.callout.medium),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (runner.run case RunnerFailed(:final why))
            Text(why, style: theme.type.caption.tint(theme.danger))
          else ...[
            fact('Files', git == null ? '—' : (git.isLoading && files == null ? '…' : '${stats.files}')),
            fact('Lines', files == null ? '—' : '+${stats.added} −${stats.removed}'),
            fact(
              'Tests',
              switch (stats.tests) {
                RunnerTests.passed => 'passed',
                RunnerTests.failed => 'failed',
                RunnerTests.notRun => 'not run',
              },
              tint: switch (stats.tests) {
                RunnerTests.passed => theme.success,
                RunnerTests.failed => theme.danger,
                RunnerTests.notRun => theme.textMuted,
              },
            ),
            fact('Cost', cost.isEmpty ? '—' : cost),
            fact('Time', stats.wall == null ? (runner.run is RunnerDone ? '—' : 'running') : wallText(stats.wall!)),
            if (files != null && files.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final f in files.take(6))
                Text(
                  '+${f.added} −${f.removed}  ${f.path}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.type.caption.mono.tint(theme.textMuted),
                ),
              if (files.length > 6)
                Text('and ${files.length - 6} more', style: theme.type.caption.tint(theme.textSubtle)),
            ],
            if (first != null) ...[
              const SizedBox(height: 8),
              Container(
                key: ValueKey('board.compare.preview.${s?.id}'),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.text.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final line in first.hunks.first.lines.take(12))
                      Text(
                        line,
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        style: theme.type.caption.mono.tint(
                          line.startsWith('+')
                              ? theme.success
                              : line.startsWith('-')
                              ? theme.danger
                              : theme.textMuted,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
          const SizedBox(height: 10),
          KitButton(
            key: ValueKey('board.compare.keep.${s?.id}'),
            label: 'Keep this one',
            expand: true,
            onPressed: canKeep && s != null ? () => Navigator.of(context).pop(s.id) : null,
          ),
        ],
      ),
    );
  }
}

/// Asks for a race (prefilled with [prompt] and [projectId]) and starts it.
Future<void> startRace(
  BuildContext context,
  WidgetRef ref, {
  String? projectId,
  String prompt = '',
  String? goalId,
}) async {
  final projects = ref.read(codeProjectsProvider);
  if (projects.isEmpty) {
    showAdaptiveToast(context, 'Open a project in Code first.');
    return;
  }
  final pick = await showRaceDialog(context, ref, projectId: projectId ?? projects.first.id, prompt: prompt);
  if (pick == null || !context.mounted) return;
  final project = ref.read(codeProjectsProvider).where((p) => p.id == pick.projectId).firstOrNull;
  if (project == null) return;
  ref.read(boardRacesProvider.notifier).start(project: project, prompt: pick.prompt, leads: pick.leads, goalId: goalId);
}

/// What a new race runs: the project, the prompt and 2–4 leads.
typedef RacePick = ({String projectId, String prompt, List<LeadPick> leads});

/// Asks for a race: its prompt, project and runners (the two leads the user starts most sessions with, picked first).
Future<RacePick?> showRaceDialog(
  BuildContext context,
  WidgetRef ref, {
  required String projectId,
  String prompt = '',
}) => showKitDialog<RacePick>(
  context,
  builder: (context) => _RaceDialog(projectId: projectId, prompt: prompt),
);

class _RaceDialog extends ConsumerStatefulWidget {
  const _RaceDialog({required this.projectId, required this.prompt});
  final String projectId;
  final String prompt;

  @override
  ConsumerState<_RaceDialog> createState() => _RaceDialogState();
}

class _RaceDialogState extends ConsumerState<_RaceDialog> {
  late final _prompt = TextEditingController(text: widget.prompt);
  late String _project = widget.projectId;
  late List<LeadPick> _picked;
  late List<LeadPick> _offered;

  @override
  void initState() {
    super.initState();
    final leads = ref.read(plannerLeadsProvider);
    final usable = {for (final l in leads) l.id};
    final fallback = [for (final l in leads) (harness: l.id, model: '')];
    _picked = defaultRunners(
      ref.read(codeSessionsProvider),
      usable: usable.contains,
      fallback: [ref.read(defaultLeadProvider), ...fallback],
    );
    _offered = {
      ...defaultRunners(ref.read(codeSessionsProvider), usable: usable.contains, fallback: fallback, count: 6),
      ...fallback,
    }.toList();
    _prompt.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final labels = {for (final l in ref.watch(plannerLeadsProvider)) l.id: l.label};
    final projects = ref.watch(codeProjectsProvider);
    final ready = _prompt.text.trim().isNotEmpty && _picked.length >= 2 && _picked.length <= 4;
    return SizedBox(
      width: 520,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Race', style: theme.type.title.semibold.tint(theme.text)),
            const SizedBox(height: 4),
            Text(
              'One prompt on 2 to 4 agents, each on its own branch. Compare what they did and keep one.',
              style: theme.type.caption.tint(theme.textMuted),
            ),
            const SizedBox(height: 12),
            AdaptiveTextField(
              key: const ValueKey('board.race.prompt'),
              controller: _prompt,
              placeholder: 'What should they do?',
              minLines: 3,
              maxLines: 8,
              autofocus: widget.prompt.isEmpty,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Text('Project', style: theme.type.caption.tint(theme.textSubtle)),
                const SizedBox(width: 6),
                AdaptiveMenuButton(
                  tooltip: 'Project',
                  actions: [
                    for (final p in projects)
                      MenuAction(
                        label: p.name,
                        checked: p.id == _project,
                        onSelected: () => setState(() => _project = p.id),
                      ),
                  ],
                  child: MenuTrigger(projects.where((p) => p.id == _project).firstOrNull?.name ?? 'Pick a project'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final l in _offered)
                  KitChip(
                    key: ValueKey('board.race.lead.${l.harness}.${l.model}'),
                    label: _leadText(labels[l.harness] ?? l.harness, l.model),
                    leading: HarnessLogo(l.harness, size: 13),
                    on: _picked.contains(l),
                    onTap: () => setState(() {
                      if (_picked.contains(l)) {
                        _picked = [..._picked]..remove(l);
                      } else if (_picked.length < 4) {
                        _picked = [..._picked, l];
                      }
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text('${_picked.length} of 2 to 4 picked', style: theme.type.caption.tint(theme.textSubtle)),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                KitButton(label: 'Cancel', style: KitButtonStyle.ghost, onPressed: () => Navigator.of(context).pop()),
                const SizedBox(width: 8),
                KitButton(
                  key: const ValueKey('board.race.start'),
                  label: 'Start race',
                  onPressed: ready
                      ? () =>
                            Navigator.of(context)
                                .pop((projectId: _project, prompt: _prompt.text.trim(), leads: _picked))
                      : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Asks what happens to the sessions a goal or race already started: kept running or stopped; null for Back.
Future<StartedChoice?> askStartedChoice(
  BuildContext context, {
  required String title,
  required String body,
  required String keyPrefix,
  String stopLabel = 'Stop them',
}) => showKitDialog<StartedChoice>(
  context,
  builder: (ctx) => KitDialog(
    title: title,
    body: Text(body),
    actions: [
      KitButton(label: 'Back', style: KitButtonStyle.ghost, shortcut: 'esc', onPressed: () => Navigator.of(ctx).pop()),
      KitButton(
        key: ValueKey('$keyPrefix.keep'),
        label: 'Keep them running',
        style: KitButtonStyle.soft,
        onPressed: () => Navigator.of(ctx).pop(StartedChoice.keepRunning),
      ),
      KitButton(
        key: ValueKey('$keyPrefix.stop'),
        label: stopLabel,
        style: KitButtonStyle.danger,
        onPressed: () => Navigator.of(ctx).pop(StartedChoice.stop),
      ),
    ],
  ),
);
