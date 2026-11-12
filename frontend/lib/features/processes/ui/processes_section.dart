// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/preferences.dart';
import '../../../core/process/supervisor.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../../../core/process/pool.dart';
import '../../code/code_providers.dart' show codeSessionsProvider;
import '../../code/live/live_pool.dart';
import '../../settings/settings_registry.dart';
import '../../settings/ui/settings_modal.dart';
import '../process_providers.dart';

/// Who a group of rows belongs to, as a heading.
String ownerHeading(ProcessOwner owner, String? Function(String id) titleOf) => switch (owner) {
  AppOwner() => 'App',
  SessionOwner(:final id) => titleOf(id) ?? 'Session $id',
  TerminalOwner(:final sessionId) => '${titleOf(sessionId) ?? 'Session $sessionId'} · terminal',
  ProbeOwner() => 'Probes',
};

DotStatus _dot(OwnedProcess p) => switch ((p.state, p.os)) {
  (ChildNotClosed() || ChildUnverified() || ChildStartFailed(), _) => DotStatus.failed,
  (_, OsMissing()) when p.state.live => DotStatus.waiting,
  (ChildRunning(), _) => DotStatus.running,
  (ChildStarting() || ChildLaunched() || ChildTerming() || ChildKilling(), _) => DotStatus.waiting,
  (ChildExited(), _) => DotStatus.done,
  (ChildDisowned(), _) => DotStatus.idle,
};

String _count(int n) => n == 1 ? '1 process' : '$n processes';

/// Settings → Code → Processes: every process EveryAI owns, by owner, with its true state.
class ProcessesSection extends ConsumerWidget {
  const ProcessesSection({super.key});

  Future<void> _stopAllNotClosed(BuildContext context, WidgetRef ref, List<OwnedProcess> rows) async {
    final sup = ref.read(processSupervisorProvider);
    final outcome = KillOutcome.merge(await Future.wait([for (final r in rows) sup.stop(r.child)]));
    if (context.mounted) showAdaptiveToast(context, killOutcomeText(outcome, _count(rows.length)));
    unawaited(ref.read(ownedProcessesProvider.notifier).refresh());
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final view = ref.watch(ownedProcessesProvider);
    final sessions = ref.watch(codeSessionsProvider);
    String? titleOf(String id) => sessions.where((s) => s.id == id).firstOrNull?.title;
    final rows = view.rows;
    final notClosed = [
      for (final r in rows)
        if (r.state is ChildNotClosed) r,
    ];
    final groups = <String, List<OwnedProcess>>{};
    final heads = <String, String>{};
    for (final r in rows) {
      (groups[r.ownerKey] ??= []).add(r);
      heads[r.ownerKey] = ownerHeading(r.owner, titleOf);
    }
    final keys = groups.keys.toList()
      ..sort((a, b) => a == 'app' ? -1 : (b == 'app' ? 1 : heads[a]!.compareTo(heads[b]!)));
    return KitGroupedList(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  key: const ValueKey('processes.header'),
                  switch (view) {
                    OwnedScanFailed(:final why) => "Couldn't read processes: $why",
                    _ => [
                      _count(rows.length),
                      if (notClosed.isNotEmpty) '${notClosed.length} not closed',
                      if (view is OwnedScanning) 'checking…',
                    ].join(' · '),
                  },
                  style: theme.type.callout.tint(
                    view is OwnedScanFailed || notClosed.isNotEmpty ? theme.danger : theme.textMuted,
                  ),
                ),
              ),
              AdaptiveIconButton(
                icon: EveryIcon.retry,
                tooltip: 'Check again',
                size: 16,
                onPressed: () => unawaited(ref.read(ownedProcessesProvider.notifier).refresh()),
              ),
            ],
          ),
        ),
        if (notClosed.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: KitButton(
                key: const ValueKey('processes.stop-all-not-closed'),
                label: 'Stop all not closed',
                style: KitButtonStyle.danger,
                onPressed: () => unawaited(_stopAllNotClosed(context, ref, notClosed)),
              ),
            ),
          ),
        if (rows.isEmpty && view is OwnedListed)
          AdaptiveListTile(title: Text('Nothing running', style: theme.type.body.tint(theme.textMuted))),
        for (final k in keys) ...[
          AdaptiveSectionHeader(heads[k]!),
          for (final r in groups[k]!) OwnedProcessRow(key: ValueKey('processes.row.${r.id}'), process: r),
        ],
        ...poolRows(),
      ],
    );
  }
}

/// Where a row's Stop is.
enum _RowAction { idle, stopping }

/// One owned process: dot, label, pid, its state in words (Not closed in the error colour), port and detail in mono,
/// and Stop (Kill again when not closed).
class OwnedProcessRow extends ConsumerStatefulWidget {
  const OwnedProcessRow({super.key, required this.process});
  final OwnedProcess process;

  @override
  ConsumerState<OwnedProcessRow> createState() => _OwnedProcessRowState();
}

class _OwnedProcessRowState extends ConsumerState<OwnedProcessRow> {
  _RowAction _action = _RowAction.idle;

  Future<void> _stop() async {
    if (_action == _RowAction.stopping) return;
    setState(() => _action = _RowAction.stopping);
    final p = widget.process;
    KillOutcome out;
    try {
      out = await ref.read(processSupervisorProvider).stop(p.child);
    } on Object catch (e) {
      out = ScanFailed('$e');
    }
    if (!mounted) return;
    setState(() => _action = _RowAction.idle);
    showAdaptiveToast(context, killOutcomeText(out, p.label));
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final p = widget.process;
    final loud = p.loud;
    final mono = theme.type.caption.mono.tint(theme.textMuted);
    final facts = [if (p.pid != null) 'pid ${p.pid}', if (p.port != null) ':${p.port}', ?p.detail].join(' · ');
    return AdaptiveListTile(
      leading: StatusDot(_dot(p)),
      title: Text(p.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            ownedStateText(p),
            key: ValueKey('processes.state.${p.id}'),
            style: theme.type.caption.tint(loud ? theme.danger : theme.textMuted),
          ),
          if (p.state case ChildNotClosed(:final reason))
            Text(reason, style: theme.type.caption.tint(theme.danger), maxLines: 2, overflow: TextOverflow.ellipsis),
          if (facts.isNotEmpty) Text(facts, style: mono, maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
      trailing: p.state.live
          ? KitButton(
              key: ValueKey('processes.stop.${p.id}'),
              label: p.state is ChildNotClosed ? 'Kill again' : 'Stop',
              style: p.state is ChildNotClosed ? KitButtonStyle.danger : KitButtonStyle.soft,
              busy: _action == _RowAction.stopping,
              onPressed: _action == _RowAction.stopping ? null : () => unawaited(_stop()),
            )
          : null,
    );
  }
}

/// The session's own processes, above the Processes tab's scanned list.
class OwnedSessionGroup extends ConsumerWidget {
  const OwnedSessionGroup({super.key, required this.sessionId});
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final view = ref.watch(ownedBySessionProvider(sessionId));
    if (view.rows.isEmpty && view is! OwnedScanFailed) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const KitLabel('Owned by EveryAI', padding: EdgeInsets.fromLTRB(4, 14, 4, 4)),
        if (view case OwnedScanFailed(:final why))
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Text("Couldn't read processes: $why", style: theme.type.caption.tint(theme.danger)),
          ),
        for (final r in view.rows) OwnedProcessRow(key: ValueKey('owned.row.${r.id}'), process: r),
      ],
    );
  }
}

/// The shell's process notices: "N processes didn't close" while any is not closed, and the one launch notice about
/// the last run's leftovers.
class ProcessNotices extends ConsumerWidget {
  const ProcessNotices({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final notClosed = ref.watch(notClosedProvider);
    final launch = ref.watch(launchNoticeProvider);
    final bad = [
      for (final p in notClosed)
        if (p.state is ChildNotClosed) p,
    ];
    Widget banner(List<Widget> children) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: GlassSurface(
        level: GlassLevel.thick,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (bad.isNotEmpty)
          banner([
            const StatusDot(DotStatus.failed),
            const SizedBox(width: 10),
            Text(
              key: const ValueKey('processes.banner'),
              bad.length == 1 ? "1 process didn't close" : "${bad.length} processes didn't close",
              style: theme.type.callout.tint(theme.danger),
            ),
            const SizedBox(width: 10),
            AdaptiveButton(
              label: 'Show',
              onPressed: () => unawaited(showSettings(context, section: SettingsSection.processes)),
            ),
          ]),
        if (launch case NoticeShowing(:final lines))
          banner([
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final l in lines)
                    Text(l.text, style: theme.type.callout.tint(l.bad ? theme.danger : theme.text)),
                ],
              ),
            ),
            const SizedBox(width: 10),
            AdaptiveIconButton(
              icon: EveryIcon.close,
              tooltip: 'Dismiss',
              size: 14,
              onPressed: () => ref.read(launchNoticeProvider.notifier).dismiss(),
            ),
          ]),
      ],
    );
  }
}

/// The pool and budget overrides (Preferences `code.pool.<kind>`, `code.process_budget`; none = Auto, sized from
/// this computer's memory and cores).
const poolSettings = <({String key, String title, String help, List<int> options})>[
  (key: 'code.pool.browser', title: 'Browsers', help: 'Live browser pages at once.', options: [1, 2, 3, 4, 6, 8, 12]),
  (key: 'code.pool.simulator', title: 'iOS simulators', help: 'Booted simulators at once.', options: [1, 2, 3, 4]),
  (key: 'code.pool.emulator', title: 'Android emulators', help: 'Running emulators at once.', options: [1, 2, 3, 4]),
  (key: 'code.pool.stream', title: 'Screen streams', help: 'Live device and window streams.', options: [1, 2, 4, 6, 8]),
  (
    key: 'code.pool.display',
    title: 'Virtual displays',
    help: 'Nested displays for app windows.',
    options: [1, 2, 4, 6, 8],
  ),
  (
    key: 'code.process_budget',
    title: 'Processes per session',
    help: 'Past this, the session is stopped and told why.',
    options: [100, 200, 400, 800, 1600],
  ),
];

/// The capacity rows (a heading, then one row per [poolSettings]).
List<Widget> poolRows() => [
  const AdaptiveSectionHeader('Capacity'),
  for (final s in poolSettings) _PoolRow(key: ValueKey('processes.pool.${s.key}'), setting: s),
  const PoolHolders(key: ValueKey('processes.pool.holders')),
];

/// Who holds each pooled resource and who waits for it, with Release for an agent's lease: the user's way out when
/// an idle holder never lets go (the pool never takes a slot back by itself).
class PoolHolders extends ConsumerWidget {
  const PoolHolders({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pool = ref.watch(livePoolProvider);
    return ListenableBuilder(
      listenable: pool,
      builder: (context, _) {
        String name(String holder) => LivePool.nameOf?.call(holder) ?? holder;
        final rows = <Widget>[
          for (final kind in ResourceKind.values) ...[
            for (final l in pool.holders(kind))
              AdaptiveListTile(
                key: ValueKey('processes.pool.lease.${l.id}'),
                title: Text('${kind.label} · ${name(l.holder)}'),
                subtitle: const Text('Holding'),
                trailing: l.holder.startsWith('agent:')
                    ? AdaptiveButton(
                        label: 'Release',
                        emphasis: ButtonEmphasis.secondary,
                        onPressed: () => pool.release(l),
                      )
                    : null,
              ),
            for (final (i, l) in pool.queued(kind).indexed)
              AdaptiveListTile(
                key: ValueKey('processes.pool.lease.${l.id}'),
                title: Text('${kind.label} · ${name(l.holder)}'),
                subtitle: Text('Waiting (${i + 1} in line)'),
              ),
          ],
        ];
        if (rows.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [const AdaptiveSectionHeader('Holding'), ...rows],
        );
      },
    );
  }
}

class _PoolRow extends ConsumerStatefulWidget {
  const _PoolRow({super.key, required this.setting});
  final ({String key, String title, String help, List<int> options}) setting;

  @override
  ConsumerState<_PoolRow> createState() => _PoolRowState();
}

class _PoolRowState extends ConsumerState<_PoolRow> {
  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(preferencesProvider);
    final s = widget.setting;
    final current = int.tryParse(prefs[s.key] ?? '');
    void pick(int? v) {
      setState(() => prefs[s.key] = v?.toString());
      // At once: a smaller number queues the next caller, a larger one lets the queue in.
      unawaited(LivePool.configure((k) => prefs[k]));
    }

    return AdaptiveListTile(
      title: Text(s.title),
      subtitle: Text(s.help),
      trailing: AdaptiveMenuButton(
        actions: [
          MenuAction(label: 'Auto', checked: current == null, onSelected: () => pick(null)),
          for (final o in s.options) MenuAction(label: '$o', checked: current == o, onSelected: () => pick(o)),
        ],
        child: MenuTrigger(current == null ? 'Auto' : '$current'),
      ),
    );
  }
}
