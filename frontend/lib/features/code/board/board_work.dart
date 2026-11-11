import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/motion/ambient.dart';
import '../../../core/motion/motion.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../../questions/ui/question_card.dart';
import '../code_providers.dart';
import '../domain/permissions.dart';
import '../domain/code_session.dart';
import '../domain/doom_loop.dart' show loopedStep;
import '../domain/transcript.dart' show QuestionItem, Transcript;
import '../harness/events.dart' show ActionCall;
import '../harness/harness.dart' show BackgroundTask;
import '../ui/console/console_state.dart';
import '../ui/harness_logo.dart';
import '../ui/console/running_work.dart' show RunBar, liveStatusOf;
import '../ui/transcript/transcript_items.dart' show approvalTitle;
import '../workflows/workflow_engine.dart';
import '../workflows/workflow_runs.dart' show workflowRunsProvider;
import 'board_providers.dart' show boardActivity;
import 'board_state.dart' show outsideSubagents;

/// What in a child's transcript [t] waits on the user: its approvals, or a question that didn't go to its
/// orchestrator ([askedLead]: a fork's own question or the loop guard's, which the orchestrator answers). A consent
/// or a workflow agent's question is the user's. Null when nothing is.
({List<ActionCall> pending, QuestionItem? question})? userWait(Transcript t, bool Function(String callId) askedLead) {
  if (t.pending.isNotEmpty) return (pending: t.pending, question: null);
  final q = t.openQuestion;
  if (q == null || askedLead(q.call.id)) return null;
  return (pending: const [], question: q);
}

/// [userWait] for child [childId] of [parentId], live; null when the child isn't open.
({List<ActionCall> pending, QuestionItem? question})? childWaitsOnUser(WidgetRef ref, String parentId, String childId) {
  if (!ref.exists(codeSessionProvider(childId))) return null;
  final t = ref.watch(codeSessionProvider(childId).select((s) => s.transcript));
  final parent = ref.exists(codeSessionProvider(parentId)) ? ref.read(codeSessionProvider(parentId).notifier) : null;
  return userWait(t, (id) => parent?.askedLead(id) ?? false);
}

/// A Board card's family tree: workflow runs with their agents, forks and subagents (ours, and an outside lead's own),
/// and commands left running. Each child shows its harness, model, current step and how long it has run; a child
/// waiting on the user comes first, with its controls under its row. Open by default for up to three rows while
/// something runs (and always while a child needs the user); more fold to one line.
class BoardWork extends ConsumerStatefulWidget {
  const BoardWork({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<BoardWork> createState() => _BoardWorkState();
}

class _BoardWorkState extends ConsumerState<BoardWork> {
  /// The user's choice; null follows the default (open while a child needs them).
  bool? _open;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final id = widget.sessionId;
    final children = ref.watch(
      codeSessionsProvider.select(
        (all) => [
          for (final s in all)
            if (s.parentId == id) s,
        ],
      ),
    );
    final runs = ref.watch(workflowRunsProvider(id));
    final live = ref.exists(codeSessionProvider(id));
    // Shells start and end with the session's events.
    final transcript = live ? ref.watch(codeSessionProvider(id).select((s) => s.transcript)) : null;
    final shells = live ? ref.read(codeSessionProvider(id).notifier).backgroundTasks : const <BackgroundTask>[];
    // An outside lead's own subagents (Claude Code's agents), from its transcript.
    final outside = transcript == null ? const <({String id, String task})>[] : outsideSubagents(transcript);
    if (runs.isEmpty && children.isEmpty && shells.isEmpty && outside.isEmpty) return const SizedBox.shrink();

    final byId = {for (final c in children) c.id: c};
    final inRuns = {
      for (final r in runs)
        for (final a in r.agents) ?a.childId,
    };
    bool over(String childId) =>
        const {SessionStatus.done, SessionStatus.failed, SessionStatus.idle}.contains(liveStatusOf(ref, childId));
    final waiting = {
      for (final c in children)
        if (childWaitsOnUser(ref, id, c.id) != null) c.id,
    };
    // Newest first, but a child waiting on the user rises to the top.
    final forks = [
      for (final c in children.reversed)
        if (!inRuns.contains(c.id) && waiting.contains(c.id)) c,
      for (final c in children.reversed)
        if (!inRuns.contains(c.id) && !waiting.contains(c.id)) c,
    ];
    final needs = waiting.length;
    final working = forks.where((c) => !over(c.id) && !waiting.contains(c.id)).length;
    final running = shells.where((t) => t.running).length;

    final summary = [
      for (final r in runs)
        '${r.name} ${r.agents.where((a) => a.status == WorkflowAgentStatus.done).length}/${r.agents.length}',
      if (working > 0) '$working running',
      if (outside.isNotEmpty) '${outside.length} ${outside.length == 1 ? 'subagent' : 'subagents'} running',
      if (forks.where((c) => over(c.id)).length case final n when n > 0) '$n done',
      if (running > 0) running == 1 ? '1 command' : '$running commands',
    ].join(' · ');
    final rows = forks.length + outside.length + shells.length + runs.fold(0, (n, r) => n + 1 + r.agents.length);
    final busy = working > 0 || outside.isNotEmpty || runs.any((r) => r.status == WorkflowStatus.running);
    final open = _open ?? (needs > 0 || (rows <= 3 && busy));
    final kinds = [runs.isNotEmpty, forks.isNotEmpty || outside.isNotEmpty, shells.isNotEmpty].where((k) => k).length;

    Widget childLine(CodeSessionInfo c) => _ChildLine(key: ValueKey('board.work.${c.id}'), parentId: id, child: c);

    return Padding(
      padding: const EdgeInsets.only(left: 36, top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            key: ValueKey('board.work.toggle.$id'),
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _open = !open),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Row(
                children: [
                  AnimatedRotation(
                    turns: open ? 0 : -0.25,
                    duration: Motion.move,
                    curve: Motion.easeInOut,
                    child: AdaptiveIcon(EveryIcon.chevronDown, size: 12, color: theme.textSubtle),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: summary, style: theme.type.caption.tint(theme.textMuted)),
                          if (needs > 0)
                            TextSpan(
                              text: '${summary.isEmpty ? '' : ' · '}$needs needs you',
                              style: theme.type.caption.medium.tint(theme.warning),
                            ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (open)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final run in runs) ...[
                    _RunHeader(run),
                    for (final a in run.agents)
                      if (a.childId case final c? when byId.containsKey(c))
                        childLine(byId[c]!)
                      else
                        _Line(dot: _agentDot(a.status), title: a.label, trailing: a.phase),
                  ],
                  if (forks.isNotEmpty || outside.isNotEmpty) ...[
                    if (kinds > 1) const _Group('Forks and subagents'),
                    for (final c in forks) childLine(c),
                    for (final a in outside)
                      _Line(
                        key: ValueKey('board.work.outside.${a.id}'),
                        dot: DotStatus.running,
                        title: a.task.isEmpty ? 'Subagent' : a.task,
                        trailing: 'running',
                      ),
                  ],
                  if (shells.isNotEmpty) ...[
                    if (kinds > 1) const _Group('Commands'),
                    for (final t in shells.reversed)
                      _Line(
                        dot: t.running ? DotStatus.running : (t.exitCode == 0 ? DotStatus.done : DotStatus.failed),
                        title: t.description.isNotEmpty ? t.description : t.command,
                        mono: t.description.isEmpty,
                        trailing: t.running ? _elapsed(t.startedAt) : 'exit ${t.exitCode}',
                      ),
                  ],
                ],
              ).settle(),
            ),
        ],
      ),
    );
  }

  static DotStatus _agentDot(WorkflowAgentStatus s) => switch (s) {
    WorkflowAgentStatus.queued => DotStatus.idle,
    WorkflowAgentStatus.running => DotStatus.running,
    WorkflowAgentStatus.done => DotStatus.done,
    WorkflowAgentStatus.failed => DotStatus.failed,
  };
}

class _Group extends StatelessWidget {
  const _Group(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => KitLabel(text, padding: const EdgeInsets.fromLTRB(0, 8, 0, 2));
}

/// A workflow run: its name, finished agents and a thin bar.
class _RunHeader extends StatelessWidget {
  const _RunHeader(this.run);
  final WorkflowRun run;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final done = run.agents.where((a) => a.status == WorkflowAgentStatus.done).length;
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  run.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.type.caption.medium.tint(theme.text),
                ),
              ),
              Text(
                run.status == WorkflowStatus.running ? '$done/${run.agents.length}' : run.status.name,
                style: theme.type.caption.mono.tint(theme.textSubtle),
              ),
            ],
          ),
          if (run.agents.isNotEmpty) ...[const SizedBox(height: 4), RunBar(done / run.agents.length)],
        ],
      ),
    );
  }
}

/// One line of work: a dot, a title, a quiet note at the end.
class _Line extends StatelessWidget {
  const _Line({super.key, required this.dot, required this.title, this.trailing = '', this.mono = false});

  final DotStatus dot;
  final String title;
  final String trailing;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          StatusDot(dot, size: 6),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: (mono ? theme.type.caption.mono : theme.type.caption).tint(theme.text),
            ),
          ),
          if (trailing.isNotEmpty) ...[
            const SizedBox(width: 8),
            Text(trailing, style: theme.type.caption.tint(theme.textSubtle)),
          ],
        ],
      ),
    );
  }
}

/// A child session: its line (a tap opens it beside the parent's chat), and under it what it waits on from the
/// user: Approve and Deny for an approval, the question itself for a question.
class _ChildLine extends ConsumerWidget {
  const _ChildLine({super.key, required this.parentId, required this.child});

  final String parentId;
  final CodeSessionInfo child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final status = liveStatusOf(ref, child.id);
    final waits = childWaitsOnUser(ref, parentId, child.id);
    // Waiting, but not on the user: its question went to the agent that started it.
    final askedLead = status == SessionStatus.needsInput && waits == null;
    void openIt() {
      ref.read(consolePanelProvider(parentId).notifier).openChild(child.id);
      context.go(Routes.codeSession(parentId));
    }

    // Read when acted on: building the row must not open (and connect) the child.
    CodeSessionController controller() => ref.read(codeSessionProvider(child.id).notifier);
    final dot = switch (status) {
      SessionStatus.starting || SessionStatus.running => DotStatus.running,
      SessionStatus.needsInput => askedLead ? DotStatus.running : DotStatus.waiting,
      SessionStatus.done => DotStatus.done,
      SessionStatus.failed => DotStatus.failed,
      SessionStatus.idle || SessionStatus.paused => DotStatus.idle,
    };
    final running = status == SessionStatus.running || status == SessionStatus.starting;
    // Its model and what it does now (while its view is open).
    final step = ref.exists(codeSessionProvider(child.id))
        ? ref.watch(codeSessionProvider(child.id).select((s) => boardActivity(s.transcript)))
        : '';
    final detail = [if (child.model.isNotEmpty) child.model.split('/').last, if (step.isNotEmpty) step].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: openIt,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        HarnessLogo(child.harness, size: 14),
                        Positioned(right: -2, bottom: -2, child: StatusDot(dot, size: 6)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          child.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.type.caption.tint(theme.text),
                        ),
                        if (detail.isNotEmpty)
                          Text(
                            detail,
                            key: ValueKey('board.work.detail.${child.id}'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.type.micro.tint(theme.textSubtle),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (running && !askedLead)
                    PeriodicRebuild(
                      period: const Duration(seconds: 1),
                      builder: (_) => Text(
                        _elapsed(child.createdAt),
                        key: ValueKey('board.work.elapsed.${child.id}'),
                        style: theme.type.caption.mono.tint(theme.textSubtle),
                      ),
                    )
                  else
                    Text(
                      askedLead ? 'asked the lead' : (waits != null ? 'needs you' : status.label),
                      style: theme.type.caption.tint(waits != null ? theme.warning : theme.textSubtle),
                    ),
                ],
              ),
            ),
          ),
        ),
        if (waits != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 0, 8),
            child: switch (waits) {
              (pending: [final call, ...], question: _) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(approvalTitle(call), style: theme.type.caption.medium.tint(theme.text)),
                  if (loopedStep(call) case final step when step.isNotEmpty)
                    Text(
                      step,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.type.caption.mono.tint(theme.textMuted),
                    ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      KitButton(
                        key: ValueKey('board.work.approve.${child.id}'),
                        label: waits.pending.length > 1 ? 'Approve ${waits.pending.length}' : 'Approve',
                        onPressed: () =>
                            controller().approve(ApprovalScope.once, [for (final c in waits.pending) c.id]),
                      ),
                      KitButton(
                        key: ValueKey('board.work.deny.${child.id}'),
                        label: 'Deny',
                        style: KitButtonStyle.ghost,
                        onPressed: () => controller().deny(null, [for (final c in waits.pending) c.id]),
                      ),
                      KitButton(label: 'Open', style: KitButtonStyle.soft, onPressed: openIt),
                    ],
                  ),
                ],
              ),
              (pending: _, question: final q?) => QuestionCard(
                key: ValueKey('board.work.question.${child.id}.${q.call.id}'),
                questions: q.questions,
                onSubmit: (answers) => controller().answer(q, answers),
              ),
              _ => const SizedBox.shrink(),
            },
          ).settle(),
      ],
    );
  }
}

String _elapsed(DateTime from) {
  final d = DateTime.now().difference(from);
  if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
  if (d.inMinutes > 0) return '${d.inMinutes}m';
  return '${d.inSeconds}s';
}
