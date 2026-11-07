import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart' as m show Tooltip;

import '../../../app/router.dart';
import '../../../core/motion/motion.dart';
import '../../../core/platform/platform_kind.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/adaptive_page.dart';
import '../../../core/ui/every_icons.dart';
import '../../questions/ui/question_card.dart';
import '../code_providers.dart';
import '../domain/permissions.dart';
import '../domain/code_session.dart';
import '../drivers/driver_registry.dart' show driverRegistryProvider;
import '../ui/harness_logo.dart';
import 'board_providers.dart';
import 'board_work.dart';

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
    final all = boardSessions(ref.watch(codeSessionsProvider), ref.watch(boardDetachedProvider));
    final statuses = ref.watch(codeStatusesProvider);
    SessionStatus statusOf(CodeSessionInfo s) {
      // Waiting sessions are opened, so their card can answer for them.
      if (statuses[s.id] == SessionStatus.needsInput &&
          !isDemoPath(s.workingDir) &&
          !ref.exists(codeSessionProvider(s.id))) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) ref.read(codeSessionProvider(s.id));
        });
      }
      // Until an opened session has connected, the polled status stands (no flicker to Done and back).
      final live = ref.exists(codeSessionProvider(s.id))
          ? ref.watch(codeSessionProvider(s.id).select((st) => st.connected || st.failure != null ? st.status : null))
          : null;
      return live ?? statuses[s.id] ?? SessionStatus.idle;
    }

    final status = {for (final s in all) s.id: statusOf(s)};
    // A cleared session that runs again comes back.
    final back = [
      for (final id in dismissed)
        if (status[id] case final st? when BoardColumn.of(st) != BoardColumn.done) id,
    ];
    if (back.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => ref.read(boardDismissedProvider.notifier).restore(back));
    }

    final harnesses = <String>{for (final s in all) s.harness}.toList();
    final harness = harnesses.contains(_harness) ? _harness : null;
    final shown = [
      for (final s in all)
        if ((harness == null || s.harness == harness) &&
            !(dismissed.contains(s.id) && BoardColumn.of(status[s.id]!) == BoardColumn.done))
          s,
    ];
    final columns = {
      for (final c in BoardColumn.values)
        c: [
          for (final s in shown)
            if (BoardColumn.of(status[s.id]!) == c) s,
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
              Text('${items.length}', style: theme.type.caption.tint(theme.textSubtle)),
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
          : LayoutBuilder(
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
              duration: const Duration(milliseconds: 140),
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
        if (!_c.isAnimating || _delta == Offset.zero) return child!;
        final t = Motion.easeInOut.transform(_c.value);
        final left = 1 - t;
        // A shallow arc: lifted most at the middle of the trip.
        final lift = -4 * t * left * (_delta.distance.clamp(0, 600) * 0.08);
        return Transform.translate(offset: Offset(_delta.dx * left, _delta.dy * left + lift), child: child);
      },
      child: widget.child,
    );
  }
}

/// One session on the Board: its harness's mark, task, where it runs and how long ago, what it is doing now, and
/// what it waits on: Approve and Deny for an approval, the question itself for a question. A Done card can be
/// cleared.
class BoardCard extends ConsumerStatefulWidget {
  const BoardCard({super.key, required this.info, required this.status, required this.harnessLabel, this.onDismiss});

  final CodeSessionInfo info;
  final SessionStatus status;
  final String harnessLabel;

  /// Clears a Done card off the Board; null elsewhere.
  final VoidCallback? onDismiss;

  @override
  ConsumerState<BoardCard> createState() => _BoardCardState();
}

class _BoardCardState extends ConsumerState<BoardCard> {
  /// Bumped when an approval from this card goes through: the button pulses.
  int _approved = 0;

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
    final waiting = widget.status == SessionStatus.needsInput;
    // A question is answered right on the card, open from the start.
    final asking = waiting && question != null;
    void openSession() => context.go(Routes.codeSession(info.id));

    return Pressable(
      onTap: openSession,
      scale: !asking,
      semanticLabel: '${info.title}, ${widget.status.label}',
      builder: (context, s, child) => AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.background,
          borderRadius: BorderRadius.circular(EveryTheme.cardRadius),
          border: Border.all(color: s.hovered ? theme.borderStrong : theme.border),
          boxShadow: s.hovered ? theme.shadowSoft : null,
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            child,
            if (widget.onDismiss case final dismiss?)
              Positioned(
                top: -8,
                right: -8,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 140),
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
                          Expanded(
                            child: Text(
                              info.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.type.callout.medium.tint(theme.text),
                            ),
                          ),
                          const SizedBox(width: 8),
                          // Room for the clear button on Done cards.
                          Padding(
                            padding: EdgeInsets.only(right: widget.onDismiss == null ? 0 : 14),
                            child: Text(_age(info.createdAt), style: theme.type.caption.mono.tint(theme.textSubtle)),
                          ),
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
            if ((activity.isNotEmpty || widget.status == SessionStatus.failed) && !asking)
              Padding(
                padding: const EdgeInsets.only(left: 36, top: 8),
                child: StateSwap(
                  child: Text(
                    widget.status == SessionStatus.failed && activity.isEmpty ? 'Failed' : activity,
                    key: ValueKey(activity),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.type.caption.tint(
                      waiting
                          ? theme.warning
                          : widget.status == SessionStatus.failed
                          ? theme.danger
                          : theme.textMuted,
                    ),
                  ),
                ),
              ),
            if (asking)
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
            BoardWork(sessionId: info.id),
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
