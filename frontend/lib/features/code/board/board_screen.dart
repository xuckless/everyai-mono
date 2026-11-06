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
import '../code_providers.dart';
import '../domain/code_session.dart';
import '../drivers/driver_registry.dart' show driverRegistryProvider;
import 'board_providers.dart';

/// Every session at a glance: Needs you, Running, Done. Approvals are answered on the card; a harness filter narrows
/// the board; forks show up once detached from their session's Running work.
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

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final all = boardSessions(ref.watch(codeSessionsProvider), ref.watch(boardDetachedProvider));
    final statuses = ref.watch(codeStatusesProvider);
    SessionStatus statusOf(CodeSessionInfo s) => ref.exists(codeSessionProvider(s.id))
        ? ref.watch(codeSessionProvider(s.id).select((st) => st.status))
        : statuses[s.id] ?? SessionStatus.idle;

    final harnesses = <String>{for (final s in all) s.harness}.toList();
    final harness = harnesses.contains(_harness) ? _harness : null;
    final shown = [
      for (final s in all)
        if (harness == null || s.harness == harness) s,
    ];
    final columns = {
      for (final c in BoardColumn.values)
        c: [
          for (final s in shown)
            if (BoardColumn.of(statusOf(s)) == c) s,
        ],
    };
    final registry = ref.read(driverRegistryProvider);
    String labelOf(String h) => h == everyaiHarnessName ? 'EveryAI' : registry.resolve(h)?.info.label ?? h;

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
              }),
            ),
          );

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
                Widget column(BoardColumn c, {required bool scrolls}) {
                  final items = columns[c]!;
                  final list = [
                    for (final (i, s) in items.indexed)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: BoardCard(
                          key: ValueKey('board.card.${s.id}.$_generation'),
                          info: s,
                          status: statusOf(s),
                          harnessLabel: labelOf(s.harness),
                        ).rowIn(i),
                      ),
                  ];
                  final head = Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
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
                      ],
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
                      Expanded(child: ListView(primary: false, children: list)),
                    ],
                  );
                }

                final body = wide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final (i, c) in BoardColumn.values.indexed) ...[
                            if (i > 0) const SizedBox(width: 14),
                            Expanded(child: column(c, scrolls: true)),
                          ],
                        ],
                      )
                    : ListView(
                        children: [
                          for (final c in BoardColumn.values)
                            if (columns[c]!.isNotEmpty)
                              Padding(padding: const EdgeInsets.only(bottom: 12), child: column(c, scrolls: false)),
                        ],
                      );
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

/// One session on the Board: its harness's mark, task, where it runs and how long ago, what it is doing now, and
/// (when it waits on an approval) Approve and Deny right on the card.
class BoardCard extends ConsumerStatefulWidget {
  const BoardCard({super.key, required this.info, required this.status, required this.harnessLabel});

  final CodeSessionInfo info;
  final SessionStatus status;
  final String harnessLabel;

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
    final transcript = open ? ref.watch(codeSessionProvider(info.id).select((s) => s.transcript)) : null;
    final activity = transcript == null ? '' : boardActivity(transcript);
    final pending = transcript?.pending ?? const [];
    final project = ref.watch(
      codeProjectsProvider.select((all) => all.where((p) => p.id == info.projectId).firstOrNull?.name),
    );
    final where = [
      ?project,
      if (info.worktree != null) 'worktree' else if (info.branch.isNotEmpty) info.branch,
      if (info.parentId != null) 'fork',
    ].join(' · ');
    final mark = harnessMark(info.harness);
    final waiting = widget.status == SessionStatus.needsInput;
    void openSession() => context.go(Routes.codeSession(info.id));

    return Pressable(
      onTap: openSession,
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
        child: child,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              m.Tooltip(
                message: widget.harnessLabel,
                child: AgentGlyph(letters: mark.letters, color: mark.color, size: 24),
              ),
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
                        Text(_age(info.createdAt), style: theme.type.caption.mono.tint(theme.textSubtle)),
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
          if (activity.isNotEmpty || widget.status == SessionStatus.failed)
            Padding(
              padding: const EdgeInsets.only(left: 36, top: 8),
              child: StateSwap(
                child: Text(
                  widget.status == SessionStatus.failed && activity.isEmpty ? 'Failed' : activity,
                  key: ValueKey(activity),
                  maxLines: 1,
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
          if (waiting)
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
                          await ref.read(codeSessionProvider(info.id).notifier).approve();
                          if (mounted) setState(() => _approved++);
                        },
                      ),
                    ),
                    KitButton(
                      key: ValueKey('board.deny.${info.id}'),
                      label: 'Deny',
                      style: KitButtonStyle.ghost,
                      onPressed: () => ref.read(codeSessionProvider(info.id).notifier).deny(),
                    ),
                  ],
                  KitButton(
                    key: ValueKey('board.open.${info.id}'),
                    label: pending.isEmpty ? 'Answer' : 'Open',
                    style: pending.isEmpty ? KitButtonStyle.primary : KitButtonStyle.soft,
                    onPressed: openSession,
                  ),
                ],
              ),
            ),
        ],
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
