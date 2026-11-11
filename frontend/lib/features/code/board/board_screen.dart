import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart' as m show Tooltip;

import '../../../app/router.dart';
import '../../../core/motion/ambient.dart';
import '../../../core/motion/motion.dart';
import '../../../core/platform/platform_kind.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/adaptive_page.dart';
import '../../../core/ui/every_icons.dart';
import '../../../core/ui/glass.dart';
import '../../models/domain/model_catalog.dart';
import '../../models/models_providers.dart';
import '../../questions/ui/question_card.dart';
import '../code_providers.dart';
import '../domain/permissions.dart';
import '../domain/fork_state.dart';
import '../domain/code_session.dart';
import '../drivers/driver_registry.dart' show driverRegistryProvider;
import '../ui/harness_logo.dart';
import 'board_providers.dart';
import 'board_state.dart';
import '../domain/transcript.dart' show QuestionItem, Transcript;
import '../harness/events.dart' show ActionCall;
import 'board_work.dart';
import '../workflows/workflow_runs.dart' show workflowRunsProvider;
import '../domain/session_work.dart';
import '../ui/stop_all_button.dart';
import '../ui/panes/browser_sign_ins.dart';
import '../ui/console/console_state.dart';
import '../workflows/workflow_engine.dart' show WorkflowStatus;

/// Every session at a glance: Needs you, Running, Done, side by side with hairlines between them (drag one to
/// resize; double-click to even them). Approvals and questions are answered on the card, Done cards can be cleared,
/// and a card glides to its new column when its session changes state. Forks show once detached from their chat.
class BoardScreen extends ConsumerStatefulWidget {
  const BoardScreen({super.key});

  @override
  ConsumerState<BoardScreen> createState() => _BoardScreenState();
}

class _BoardScreenState extends ConsumerState<BoardScreen> {
  /// The harness shown, or null for all.
  String? _harness;

  /// Bumped on a filter change, so the cards stagger in again.
  int _generation = 0;

  /// One key per card for this filter: a card keeps its state (and glides) as it moves between columns.
  final _keys = <String, GlobalKey>{};

  /// Column shares while a divider is dragged (written when it ends).
  List<double>? _dragging;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final dismissed = ref.watch(boardDismissedProvider);
    final sessions = ref.watch(codeSessionsProvider);
    final all = boardSessions(sessions, ref.watch(boardDetachedProvider));
    final statuses = ref.watch(codeStatusesProvider);
    // A session's own status: live once its controller has connected, else the polled one.
    SessionStatus ownOf(CodeSessionInfo s) {
      final live = ref.exists(codeSessionProvider(s.id))
          ? ref.watch(codeSessionProvider(s.id).select((st) => st.connected || st.failure != null ? st.status : null))
          : null;
      return live ?? statuses[s.id] ?? SessionStatus.idle;
    }

    final childrenOf = childrenByParent(sessions);

    // Waiting sessions are opened, so their card can answer for them.
    void openIfWaiting(CodeSessionInfo s) {
      if (statuses[s.id] == SessionStatus.needsInput &&
          !isDemoPath(s.workingDir) &&
          !ref.exists(codeSessionProvider(s.id))) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) ref.read(codeSessionProvider(s.id));
        });
      }
    }

    // What each session runs besides its lead's turn.
    BoardWorkCount workOf(CodeSessionInfo s) => (
      forks: runningDescendants(s.id, childrenOf, ownOf),
      subagents: ref.exists(codeSessionProvider(s.id))
          ? ref.watch(codeSessionProvider(s.id).select((st) => outsideSubagents(st.transcript).length))
          : 0,
      workflows: ref.watch(workflowRunsProvider(s.id)).where((r) => r.status == WorkflowStatus.running).length,
    );

    final work = <String, BoardWorkCount>{};
    final own = <String, SessionStatus>{};
    final waitsOnChild = <String, bool>{};
    for (final s in all) {
      openIfWaiting(s);
      // Until an opened session has connected, the polled status stands (no flicker to Done and back).
      own[s.id] = ownOf(s);
      work[s.id] = workOf(s);
      waitsOnChild[s.id] = (childrenOf[s.id] ?? const <CodeSessionInfo>[]).any(
        (c) => childWaitsOnUser(ref, s.id, c.id) != null,
      );
    }
    // The session's status as the rest of the app reads it (Running while its work runs), for its recent events.
    final status = {
      for (final s in all)
        s.id: boardStatus(own[s.id]!, workRunning: hasBoardWork(work[s.id]!), childWaits: waitsOnChild[s.id]!),
    };
    // The phase without "seen", which needs when it finished (below).
    BoardPhase phaseOf(String id, {bool seen = false}) =>
        boardPhase(own[id]!, work: work[id]!, childWaits: waitsOnChild[id]!, seen: seen);
    final columnOf = {for (final s in all) s.id: phaseOf(s.id).column};

    // A cleared session that runs again comes back.
    final back = [
      for (final id in dismissed)
        if (columnOf[id] case final c? when c != BoardColumn.done) id,
    ];
    if (back.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => ref.read(boardDismissedProvider.notifier).restore(back));
    }
    // Old finishes clear by themselves ([staleDone]): Done keeps the last two days, at most [boardDoneKeep].
    final known = ref.watch(boardDoneSinceProvider);
    final doneSince = <String, DateTime>{
      for (final s in all)
        if (columnOf[s.id] == BoardColumn.done && !dismissed.contains(s.id))
          s.id: switch (known?[s.id]) {
            final ms? => DateTime.fromMillisecondsSinceEpoch(ms),
            // Before the Board first recorded anything, from when it started; since then, from now.
            null => known == null ? s.createdAt : DateTime.now(),
          },
    };
    final stale = staleDone(doneSince, now: DateTime.now());
    final seenAt = ref.watch(boardSeenProvider);
    final phase = {for (final s in all) s.id: phaseOf(s.id, seen: seenSince(seenAt[s.id], doneSince[s.id]))};
    // Sessions running again lose their seen mark, so their next finish shows as new; deleted sessions lose theirs too.
    final ids = {for (final s in sessions) s.id};
    final rerun = [
      for (final id in seenAt.keys)
        if (!ids.contains(id) || (columnOf[id] != null && columnOf[id] != BoardColumn.done)) id,
    ];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(boardDoneSinceProvider.notifier).sync({
        for (final e in doneSince.entries)
          if (!stale.contains(e.key)) e.key: e.value,
      });
      if (stale.isNotEmpty) ref.read(boardDismissedProvider.notifier).dismiss(stale);
      if (rerun.isNotEmpty) ref.read(boardSeenProvider.notifier).forget(rerun);
    });

    final harnesses = <String>{for (final s in all) s.harness}.toList();
    final harness = harnesses.contains(_harness) ? _harness : null;
    final shown = [
      for (final s in all)
        if ((harness == null || s.harness == harness) &&
            !(dismissed.contains(s.id) && columnOf[s.id] == BoardColumn.done))
          s,
    ];
    final columns = {
      for (final c in BoardColumn.values)
        c: [
          for (final s in shown)
            if (columnOf[s.id] == c) s,
        ],
    };
    final registry = ref.read(driverRegistryProvider);
    String labelOf(String h) => h == everyaiHarnessName ? 'EveryAI' : registry.resolve(h)?.info.label ?? h;
    GlobalKey keyOf(String id) => _keys.putIfAbsent(id, () => GlobalKey(debugLabel: 'board.$id'));

    final filters = harnesses.length < 2
        ? null
        : SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: KitSegmented<String?>(
              key: const ValueKey('board.filter'),
              values: [null, ...harnesses],
              selected: harness,
              label: (h) => h == null ? 'All' : labelOf(h),
              onSelected: (h) => setState(() {
                _harness = h;
                _generation++;
                _keys.clear();
              }),
            ),
          );

    Widget column(BoardColumn c, {required bool scrolls}) {
      final items = columns[c]!;
      final list = [
        for (final (i, s) in items.indexed)
          Padding(
            key: ValueKey('board.slot.${s.id}'),
            padding: const EdgeInsets.only(bottom: 8),
            child: _Glide(
              key: keyOf(s.id),
              column: c,
              child: BoardCard(
                key: ValueKey('board.card.${s.id}.$_generation'),
                info: s,
                status: status[s.id]!,
                phase: phase[s.id]!,
                work: work[s.id]!,
                harnessLabel: labelOf(s.harness),
                onDismiss: c == BoardColumn.done
                    ? () => ref.read(boardDismissedProvider.notifier).dismiss([s.id])
                    : null,
              ).rowIn(i),
            ),
          ),
      ];
      final head = Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 4, 8),
        child: SizedBox(
          height: 28,
          child: Row(
            children: [
              StatusDot(switch (c) {
                BoardColumn.needsYou => DotStatus.waiting,
                BoardColumn.running => DotStatus.running,
                BoardColumn.done => DotStatus.done,
              }),
              const SizedBox(width: 8),
              Text(c.label, style: theme.type.callout.semibold.tint(theme.text)),
              const SizedBox(width: 8),
              TickingCount(items.length, style: theme.type.caption.mono.tint(theme.textSubtle)),
              const Spacer(),
              if (c == BoardColumn.done && items.isNotEmpty)
                KitButton(
                  key: const ValueKey('board.clear-done'),
                  label: 'Clear',
                  style: KitButtonStyle.ghost,
                  onPressed: () => ref.read(boardDismissedProvider.notifier).dismiss([for (final s in items) s.id]),
                ),
            ],
          ),
        ),
      );
      if (!scrolls) {
        return Column(
          key: ValueKey('board.column.${c.name}'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [head, ...list],
        );
      }
      return Column(
        key: ValueKey('board.column.${c.name}'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          head,
          Expanded(
            child: ListView(
              primary: false,
              padding: const EdgeInsets.only(bottom: 16),
              // Every card stays built, so a card's key can move to another column mid-scroll.
              scrollCacheExtent: const ScrollCacheExtent.pixels(100000),
              children: list,
            ),
          ),
        ],
      );
    }

    return AdaptivePage(
      title: 'Board',
      actions: [
        // One host for now: this computer.
        Padding(
          padding: const EdgeInsets.only(right: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const StatusDot(DotStatus.done),
              const SizedBox(width: 7),
              Text('This computer', style: theme.type.caption.tint(theme.textMuted)),
            ],
          ),
        ),
        if (Host.isDesktop)
          KitButton(
            key: const ValueKey('board.new'),
            label: 'New session',
            icon: EveryIcon.add,
            onPressed: () => context.go(Routes.code),
          ),
      ],
      body: all.isEmpty
          ? Center(child: Text('No sessions yet', style: theme.type.callout.tint(theme.textSubtle)))
          : GlowBackdrop(
              child: AmbientClock(
                // One breathing clock for every card, and only while something breathes.
                running: phase.values.any((p) => p.active || p == BoardPhase.needsYou),
                child: LayoutBuilder(
                  builder: (context, box) {
                    final wide = box.maxWidth >= 860;
                    final Widget body;
                    if (wide) {
                      final List<double> shares = _dragging ?? ref.watch(boardColumnsProvider);
                      final width = box.maxWidth - 28 - 2 * _Divider.hit;
                      // Each column keeps at least 220pt.
                      const min = 220.0;
                      List<double> moved(int divider, double dx, List<double> from) {
                        final w = [for (final v in from) v * width];
                        final a = (w[divider] + dx).clamp(min, w[divider] + w[divider + 1] - min);
                        w[divider + 1] = w[divider] + w[divider + 1] - a;
                        w[divider] = a;
                        return [for (final v in w) v / width];
                      }

                      Widget divider(int i) => _Divider(
                        key: ValueKey('board.divider.$i'),
                        onDrag: (dx) => setState(() => _dragging = moved(i, dx, _dragging ?? shares)),
                        onEnd: () {
                          if (_dragging case final d?) ref.read(boardColumnsProvider.notifier).set(d);
                          setState(() => _dragging = null);
                        },
                        onReset: ref.read(boardColumnsProvider.notifier).reset,
                      );
                      body = Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final (i, c) in BoardColumn.values.indexed) ...[
                            if (i > 0) divider(i - 1),
                            SizedBox(width: shares[i] * width, child: column(c, scrolls: true)),
                          ],
                        ],
                      );
                    } else {
                      body = ListView(
                        children: [
                          for (final c in BoardColumn.values)
                            if (columns[c]!.isNotEmpty)
                              Padding(padding: const EdgeInsets.only(bottom: 12), child: column(c, scrolls: false)),
                        ],
                      );
                    }
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (filters != null)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(4, 0, 4, 14),
                              child: Align(alignment: Alignment.centerLeft, child: filters),
                            ),
                          Expanded(child: body),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
    );
  }
}

/// A hairline between two columns; drag it to resize them, double-click to even all three.
class _Divider extends StatefulWidget {
  const _Divider({super.key, required this.onDrag, required this.onEnd, required this.onReset});

  /// Width of the grab area; the line itself is one pixel.
  static const hit = 13.0;

  final ValueChanged<double> onDrag;
  final VoidCallback onEnd;
  final VoidCallback onReset;

  @override
  State<_Divider> createState() => _DividerState();
}

class _DividerState extends State<_Divider> {
  bool _hover = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final active = _hover || _dragging;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        dragStartBehavior: DragStartBehavior.down,
        onHorizontalDragStart: (_) => setState(() => _dragging = true),
        onHorizontalDragUpdate: (d) => widget.onDrag(d.delta.dx),
        onHorizontalDragEnd: (_) {
          setState(() => _dragging = false);
          widget.onEnd();
        },
        onDoubleTap: widget.onReset,
        child: SizedBox(
          width: _Divider.hit,
          child: Center(
            child: AnimatedContainer(
              duration: Motion.press,
              width: active ? 2 : 1,
              color: active ? theme.accent.withValues(alpha: 0.6) : theme.border,
            ),
          ),
        ),
      ),
    );
  }
}

/// Moves its child smoothly to where it now sits when it changes [column]: from its last place on screen to its
/// new one along a gentle arc, ease-in-out (the same element moves; it isn't drawn twice).
class _Glide extends StatefulWidget {
  const _Glide({super.key, required this.column, required this.child});

  final BoardColumn column;
  final Widget child;

  @override
  State<_Glide> createState() => _GlideState();
}

class _GlideState extends State<_Glide> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 520));

  /// Where the card was last laid out, in global coordinates.
  Offset? _last;

  /// Set when the column changed: the old place to glide from.
  Offset? _from;
  Offset _delta = Offset.zero;

  @override
  void didUpdateWidget(_Glide old) {
    super.didUpdateWidget(old);
    if (old.column != widget.column && _last != null && !Motion.reduced(context)) _from = _last;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _measure() {
    if (!mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return;
    final now = box.localToGlobal(Offset.zero);
    if (_from case final from?) {
      _from = null;
      setState(() => _delta = from - now);
      _c.forward(from: 0);
    }
    _last = now;
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        // One structure moving or not (no painter, no offset at rest), so the card under it is never rebuilt.
        final moving = _c.isAnimating && _delta != Offset.zero;
        // Where the card is at [v] of the trip: a shallow arc, lifted most at the middle.
        Offset at(double v) {
          final t = Motion.easeInOut.transform(v.clamp(0, 1));
          final left = 1 - t;
          final lift = -4 * t * left * (_delta.distance.clamp(0, 600) * 0.08);
          return Offset(_delta.dx * left, _delta.dy * left + lift);
        }

        final now = moving ? at(_c.value) : Offset.zero;
        // A soft light trail behind it, fading as it lands.
        return CustomPaint(
          painter: moving
              ? TrailPainter(
                  from: at(_c.value - 0.22),
                  to: now,
                  color: EveryTheme.of(context).accent,
                  opacity: 1 - _c.value,
                )
              : null,
          child: Transform.translate(offset: now, child: child),
        );
      },
      child: widget.child,
    );
  }
}

/// One session on the Board: its harness's mark, task, where it runs and how long ago, what it is doing now, and
/// what it waits on: Approve and Deny for an approval, the question itself for a question. A Done card can be
/// cleared.
class BoardCard extends ConsumerStatefulWidget {
  const BoardCard({
    super.key,
    required this.info,
    required this.status,
    required this.harnessLabel,
    required this.phase,
    this.work = noBoardWork,
    this.onDismiss,
  });

  final CodeSessionInfo info;

  /// Its status as the rest of the app reads it (for its recent events).
  final SessionStatus status;

  /// What the card shows ([boardPhase]).
  final BoardPhase phase;

  /// What it runs besides its lead's turn.
  final BoardWorkCount work;
  final String harnessLabel;

  /// Clears a Done card off the Board; null elsewhere.
  final VoidCallback? onDismiss;

  @override
  ConsumerState<BoardCard> createState() => _BoardCardState();
}

/// A warning action in flight from a card (a second click meanwhile does nothing).
enum _Act { idle, nudging, stopping, compacting }

/// What Nudge sends: a short ask for a status.
/// Prompt reason: a stalled agent should say what it is doing, not start over.
const boardNudgeText =
    'Quick status check from the Board: what are you doing right now, and is anything stuck? Reply in one or two '
    'lines, then carry on.';

class _BoardCardState extends ConsumerState<BoardCard> {
  /// Bumped when an approval from this card goes through: the button pulses.
  int _approved = 0;

  /// Bumped when the session finishes while on the Board: the card bursts.
  int _finished = 0;

  var _act = _Act.idle;

  @override
  void didUpdateWidget(BoardCard old) {
    super.didUpdateWidget(old);
    if (old.phase.active && widget.phase.column == BoardColumn.done && widget.phase != BoardPhase.failed) _finished++;
  }

  Future<void> _run(_Act act, Future<void> Function() action) async {
    if (_act != _Act.idle) return;
    setState(() => _act = act);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _act = _Act.idle);
    }
  }

  /// Stall, loop and context warnings for an open session, re-read on the card's clock.
  List<BoardWarning> _warnings(Transcript? live) {
    if (live == null) return const [];
    final id = widget.info.id;
    final connected = ref.read(codeSessionProvider(id)).connected;
    final usage = ref.exists(codeUsageProvider(id)) ? ref.read(codeUsageProvider(id)).value : null;
    // The catalog only when there is a reading to measure against it.
    final window = (usage?.contextTokens ?? 0) == 0
        ? 0
        : ref.read(modelCatalogProvider)[ModelId(widget.info.model)]?.contextLength ?? 0;
    return boardWarnings(
      phase: widget.phase,
      sinceProgress: DateTime.now().difference(ref.read(boardProgressProvider(id).notifier).last()),
      connected: connected,
      repeated: repeatedStep(live),
      contextPercent: contextPercent(usage?.contextTokens ?? 0, window),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final info = widget.info;
    final open = ref.exists(codeSessionProvider(info.id));
    final live = open ? ref.watch(codeSessionProvider(info.id).select((s) => s.transcript)) : null;
    // A closed session: what it last did, from its harness's files.
    final transcript = live ?? ref.watch(boardRecentTranscriptProvider((info.id, widget.status))).value;
    final activity = transcript == null ? '' : boardActivity(transcript);
    final pending = live?.pending ?? const [];
    final question = live?.openQuestion;
    final project = ref.watch(
      codeProjectsProvider.select((all) => all.where((p) => p.id == info.projectId).firstOrNull?.name),
    );
    final where = [
      ?project,
      if (info.worktree != null) 'worktree' else if (info.branch.isNotEmpty) info.branch,
      if (info.parentId != null) 'fork',
    ].join(' · ');
    final phase = widget.phase;
    final waiting = phase == BoardPhase.needsYou;
    final failed = phase == BoardPhase.failed;
    final phaseLine = boardPhaseLine(phase, widget.work);
    // Keeps the progress clock running for an open session (the card reads it on its own clock).
    if (open) ref.watch(boardProgressProvider(info.id).select((_) => 0));
    // Stop all, while an open session runs anything (the lead's turn, forks, a workflow).
    final controller = open ? ref.read(codeSessionProvider(info.id).notifier) : null;
    if (open) ref.watch(workflowRunsProvider(info.id));
    final work = controller?.runningWork;
    final leadBusy = live != null && (live.running || live.pending.isNotEmpty);
    final stopAll = controller != null && work != null && (leadBusy || hasSideWork(work))
        ? StopAllButton(
            key: ValueKey('board.stop-all.${info.id}'),
            work: work,
            leadBusy: leadBusy,
            onStopAll: controller.stopAll,
            onPauseAll: ref.watch(codeSessionProvider(info.id).select((s) => s.hold)) == StepHold.none
                ? controller.pauseAll
                : null,
            size: 22,
          )
        : null;
    // A question is answered right on the card, open from the start.
    final asking = waiting && question != null;
    void openSession() {
      ref.read(boardSeenProvider.notifier).see(info.id);
      context.go(Routes.codeSession(info.id));
    }

    const radius = EveryTheme.cardRadius;
    // Warnings move with the clock; everything else rebuilds on its own changes.
    return PeriodicRebuild(
      period: const Duration(seconds: 30),
      builder: (context) {
        final warnings = _warnings(live);
        final edge = failed ? theme.danger : (warnings.isNotEmpty ? theme.warning : null);
        return FinishBurst(
          trigger: _finished == 0 ? null : _finished,
          color: theme.success,
          child: BreathingRing(
            active: waiting,
            color: theme.warning,
            radius: radius,
            child: GlowPulse(
              active: phase.active,
              color: theme.accent,
              radius: radius,
              strength: phase == BoardPhase.working ? 1 : 0.55,
              child: _body(
                theme: theme,
                warnings: warnings,
                edge: edge,
                openSession: openSession,
                asking: asking,
                stopAll: stopAll,
                live: live,
                pending: pending,
                question: question,
                activity: activity,
                where: where,
                phaseLine: phaseLine,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _body({
    required EveryTheme theme,
    required List<BoardWarning> warnings,
    required Color? edge,
    required VoidCallback openSession,
    required bool asking,
    required Widget? stopAll,
    required Transcript? live,
    required List<ActionCall> pending,
    required QuestionItem? question,
    required String activity,
    required String where,
    required String phaseLine,
  }) {
    final info = widget.info;
    final phase = widget.phase;
    final waiting = phase == BoardPhase.needsYou;
    final failed = phase == BoardPhase.failed;
    return Pressable(
      onTap: openSession,
      scale: !asking,
      semanticLabel: '${info.title}, ${widget.status.label}',
      builder: (context, s, child) => AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(14),
        decoration: glassDecoration(theme, hovered: s.hovered, edge: edge, radius: EveryTheme.cardRadius),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            child,
            if (widget.onDismiss case final dismiss?)
              Positioned(
                top: -8,
                right: -8,
                child: AnimatedOpacity(
                  duration: Motion.press,
                  opacity: s.hovered || Host.isMobile ? 1 : 0,
                  child: KitIconButton(
                    key: ValueKey('board.dismiss.${info.id}'),
                    icon: EveryIcon.close,
                    tooltip: 'Clear from the Board',
                    size: 14,
                    onPressed: dismiss,
                  ),
                ),
              ),
          ],
        ),
      ),
      child: AnimatedSize(
        duration: Motion.move,
        curve: Motion.easeInOut,
        alignment: Alignment.topCenter,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                m.Tooltip(message: widget.harnessLabel, child: HarnessLogo(info.harness, size: 24)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          if (phase == BoardPhase.doneUnseen)
                            Padding(
                              key: ValueKey('board.unseen.${info.id}'),
                              padding: const EdgeInsets.only(right: 6),
                              child: Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(color: theme.accent, shape: BoxShape.circle),
                              ),
                            ),
                          Expanded(
                            child: Text(
                              info.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.type.callout.medium.tint(
                                phase == BoardPhase.doneSeen ? theme.textMuted : theme.text,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          // Room for the clear button on Done cards.
                          Padding(
                            padding: EdgeInsets.only(right: widget.onDismiss == null ? 0 : 14),
                            child: Text(_age(info.createdAt), style: theme.type.caption.mono.tint(theme.textSubtle)),
                          ),
                          if (stopAll != null) ...[const SizedBox(width: 6), stopAll],
                        ],
                      ),
                      if (where.isNotEmpty)
                        Text(
                          where,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.type.caption.tint(theme.textSubtle),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (phaseLine.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 36, top: 8),
                child: Text(
                  phaseLine,
                  key: ValueKey('board.phase.${info.id}'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.type.caption.medium.tint(theme.accentText),
                ),
              ),
            if ((activity.isNotEmpty || failed) && !asking)
              Padding(
                padding: const EdgeInsets.only(left: 36, top: 8),
                child: StateSwap(
                  child: Text(
                    failed && activity.isEmpty ? 'Failed' : activity,
                    key: ValueKey(activity),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.type.caption.tint(
                      waiting
                          ? theme.warning
                          : failed
                          ? theme.danger
                          : theme.textMuted,
                    ),
                  ),
                ),
              ),
            if (asking && question != null)
              Padding(
                key: ValueKey('board.question.${info.id}'),
                padding: const EdgeInsets.only(top: 10),
                child: QuestionCard(
                  // A new question is a new card: picks and the sent state belong to one call.
                  key: ValueKey('board.question.card.${question.call.id}'),
                  questions: question.questions,
                  onSubmit: (answers) async {
                    await ref.read(codeSessionProvider(info.id).notifier).answer(question, answers);
                  },
                ).settle(),
              ),
            if (warnings.isNotEmpty)
              _Warnings(
                info: info,
                warnings: warnings,
                live: live,
                state: this,
                // Compact works on an idle EveryAI-led session; an outside CLI keeps its own context.
                compactable:
                    live != null &&
                    !live.running &&
                    live.pending.isEmpty &&
                    live.held.isEmpty &&
                    !isOutsideLead(info.harness, info.workingDir),
              ),
            BoardWork(sessionId: info.id),
            Padding(
              padding: const EdgeInsets.only(left: 36, top: 8),
              child: LoginWallCard(
                sessionId: info.id,
                projectId: info.projectId,
                onOpen: () {
                  ref.read(consolePanelProvider(info.id).notifier).show(ConsoleView.preview);
                  openSession();
                },
              ),
            ),
            // Its own approvals; Open for a waiting session not open here yet (one whose child waits shows that above).
            if (waiting && !asking && (pending.isNotEmpty || live == null))
              Padding(
                padding: const EdgeInsets.only(left: 36, top: 10),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (pending.isNotEmpty) ...[
                      SuccessPulse(
                        trigger: _approved,
                        child: KitButton(
                          key: ValueKey('board.approve.${info.id}'),
                          label: 'Approve',
                          onPressed: () async {
                            // The calls this card showed: a batch that came in since then waits for its own look.
                            await ref.read(codeSessionProvider(info.id).notifier).approve(ApprovalScope.once, [
                              for (final c in pending) c.id,
                            ]);
                            if (mounted) setState(() => _approved++);
                          },
                        ),
                      ),
                      KitButton(
                        key: ValueKey('board.deny.${info.id}'),
                        label: 'Deny',
                        style: KitButtonStyle.ghost,
                        onPressed: () =>
                            ref.read(codeSessionProvider(info.id).notifier).deny(null, [for (final c in pending) c.id]),
                      ),
                    ],
                    KitButton(
                      key: ValueKey('board.open.${info.id}'),
                      label: 'Open',
                      style: KitButtonStyle.soft,
                      onPressed: openSession,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _age(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'now';
    if (d.inHours < 1) return '${d.inMinutes}m';
    if (d.inDays < 1) return '${d.inHours}h';
    return '${d.inDays}d';
  }
}

/// A card's warnings (stalled, looping, context nearly full), each as an amber line, with Nudge, Stop and, when the
/// context is the problem, Compact. One action at a time ([_Act]).
class _Warnings extends StatelessWidget {
  const _Warnings({
    required this.info,
    required this.warnings,
    required this.live,
    required this.state,
    required this.compactable,
  });

  final CodeSessionInfo info;
  final List<BoardWarning> warnings;
  final Transcript? live;
  final _BoardCardState state;

  /// Whether Compact would do anything now (else it would only say the agent is busy).
  final bool compactable;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final controller = state.ref.read(codeSessionProvider(info.id).notifier);
    final idle = state._act == _Act.idle;
    return Padding(
      key: ValueKey('board.warnings.${info.id}'),
      padding: const EdgeInsets.only(left: 36, top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final w in warnings)
            Text(
              w.line,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.type.caption.medium.tint(theme.warning),
            ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              KitButton(
                key: ValueKey('board.nudge.${info.id}'),
                label: 'Nudge',
                style: KitButtonStyle.soft,
                onPressed: !idle
                    ? null
                    : () => state._run(_Act.nudging, () async {
                        // Joins the running turn after its current step (a long build isn't cut off); an idle lead
                        // gets it as its next message.
                        await controller.tellWhileRunning(boardNudgeText, fromUser: true);
                      }),
              ),
              KitButton(
                key: ValueKey('board.stop.${info.id}'),
                label: 'Stop',
                style: KitButtonStyle.ghost,
                onPressed: !idle ? null : () => state._run(_Act.stopping, controller.stop),
              ),
              if (compactable && warnings.any((w) => w is BoardContextFull))
                KitButton(
                  key: ValueKey('board.compact.${info.id}'),
                  label: 'Compact',
                  style: KitButtonStyle.ghost,
                  onPressed: !idle
                      ? null
                      : () => state._run(_Act.compacting, () async {
                          final outcome = await controller.compact();
                          if (!context.mounted) return;
                          showAdaptiveToast(context, switch (outcome.kind) {
                            CompactKind.compacted => 'Compacted: older turns are now a summary.',
                            CompactKind.nothing => 'Nothing to compact yet.',
                            CompactKind.busy => 'The agent is busy; compact when it stops.',
                            CompactKind.failed => "Couldn't compact: ${outcome.message}",
                          });
                        }),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
