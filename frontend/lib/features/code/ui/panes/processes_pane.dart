import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/motion/motion.dart';
import '../../../../core/preferences.dart';
import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/every_icons.dart';
import '../../domain/code_session.dart';
import '../../domain/local_ports.dart';
import '../../panes/panes_providers.dart';
import '../../panes/processes.dart';
import '../../shells/containers.dart';
import '../../shells/shell_registry.dart';
import '../../shells/shells_providers.dart';
import '../console/console_state.dart';

final _mono = EveryType.resolve().caption.mono.copyWith(height: 1.4);

/// What the session has running: the agent's background jobs and servers,
/// and what was started from the Terminal pane, with their ports.
class ProcessesPane extends ConsumerWidget {
  const ProcessesPane({super.key, required this.session});

  final CodeSessionInfo session;

  Future<void> _kill(BuildContext context, WidgetRef ref, SessionProcess p, {bool force = false}) async {
    final out = await killProcess(p.pid, force: force);
    if (context.mounted) showAdaptiveToast(context, killToast(out, p.name, p.pid, force: force));
    ref.invalidate(sessionProcessesProvider(session.id));
  }

  void _preview(WidgetRef ref, ListeningPort port) {
    ref.read(previewUrlProvider(session.id).notifier).set(urlForPort(port.port));
    ref.read(consolePanelProvider(session.id).notifier).show(ConsoleView.preview);
  }

  /// Opens the drawer's tab that follows [shell] (its log so far, then live).
  void _open(WidgetRef ref, ShellEntry shell) {
    ref.read(terminalTabsProvider(session.id).notifier).openShell(shell.key);
    ref.read(codePaneProvider(session.id).notifier).show(CodePane.terminal);
  }

  /// Opens a drawer tab named [label] running [command] (a container's logs or a shell inside it).
  void _run(WidgetRef ref, String label, String command) {
    ref.read(terminalTabsProvider(session.id).notifier).addCommand(label, command);
    ref.read(codePaneProvider(session.id).notifier).show(CodePane.terminal);
  }

  /// A process EveryAI didn't start (an outside lead's, the user's terminal job): tails its output when that goes
  /// to a file, else says it can't be shown.
  Future<void> _follow(BuildContext context, WidgetRef ref, SessionProcess p) async {
    final file = await outputFileOf(p.pid);
    if (!context.mounted) return;
    if (file == null) {
      showAdaptiveToast(
        context,
        p.origin == ProcessOrigin.terminal
            ? 'It runs in one of your terminal tabs: its output is there.'
            : "Started outside EveryAI's shells: its output isn't available. Stop and the ports still work.",
      );
      return;
    }
    _run(ref, 'output · ${p.name}', "tail -n 500 -f '${file.replaceAll("'", r"'\''")}'");
  }

  void _logs(WidgetRef ref, SessionContainer c) =>
      _run(ref, 'logs · ${c.name}', '${c.cli} logs -f --tail 500 ${c.shortId}');

  Future<void> _stopContainer(BuildContext context, WidgetRef ref, SessionContainer c) async {
    final ok = await stopContainer(c);
    if (context.mounted) showAdaptiveToast(context, ok ? 'Stopped ${c.name}' : "Couldn't stop ${c.name}");
    ref.invalidate(sessionContainersProvider(session.id));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final containers = ref.watch(sessionContainersProvider(session.id)).value ?? const <SessionContainer>[];
    final snapshot = ref.watch(sessionProcessesProvider(session.id));
    final list = snapshot.value ?? const <SessionProcess>[];
    final shells = ref.watch(sessionShellsProvider(session.id)).value ?? const <ShellEntry>[];
    final groups = groupByShell(shells, list);
    final running = [
      for (final g in groups)
        if (g.shell.running) g,
    ];
    final done = finishedShells(groups);
    final doneOpen = !ref.watch(processesDoneFoldedProvider);
    final others = otherProcesses(groups, list);
    final empty = groups.isEmpty && others.isEmpty && containers.isEmpty;
    Widget header(String text) => KitLabel(text, padding: const EdgeInsets.fromLTRB(4, 14, 4, 4));
    Widget shellRow(ShellGroup g) => _ShellRow(
      group: g,
      onOpen: () => _open(ref, g.shell),
      onStop: g.shell.running ? () => g.shell.live?.stop() : null,
      onRestart: g.shell.restart,
      onPreview: (port) => _preview(ref, port),
      onStopChild: (p) => _kill(context, ref, p),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  snapshot.error is ProcessesUnreadableError
                      ? "Couldn't read processes"
                      : snapshot.isLoading && snapshot.value == null && shells.isEmpty
                      ? 'Looking…'
                      : '${running.length + others.length} running · '
                            '${list.fold(0, (n, p) => n + p.ports.length)} listening',
                  style: theme.type.caption.tint(theme.textMuted),
                ),
              ),
              AdaptiveIconButton(
                icon: EveryIcon.retry,
                tooltip: 'Refresh',
                size: 16,
                onPressed: () => ref.invalidate(sessionProcessesProvider(session.id)),
              ),
            ],
          ),
        ),
        Expanded(
          child: empty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Nothing running. Servers, background jobs and commands the agent or the terminal starts show '
                      'here; click one to see its output.',
                      textAlign: TextAlign.center,
                      style: theme.type.callout.tint(theme.textMuted),
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                  children: [
                    if (running.isNotEmpty) ...[header('Running'), for (final g in running) shellRow(g)],
                    if (others.isNotEmpty) ...[
                      header(running.isEmpty ? 'Running' : 'Other processes'),
                      for (final p in others)
                        _ProcessRow(
                          process: p,
                          onOpen: () => _follow(context, ref, p),
                          onStop: () => _kill(context, ref, p),
                          onForceQuit: () => _kill(context, ref, p, force: true),
                          onPreview: (port) => _preview(ref, port),
                        ),
                    ],
                    if (containers.isNotEmpty) ...[
                      header('Containers'),
                      for (final c in containers)
                        _ContainerRow(
                          container: c,
                          onLogs: () => _logs(ref, c),
                          onShell: () => _run(
                            ref,
                            'shell · ${c.name}',
                            "${c.cli} exec -it ${c.shortId} sh -c 'command -v bash >/dev/null && exec bash || exec sh'",
                          ),
                          onStop: () => _stopContainer(context, ref, c),
                          onPreview: (port) => _preview(ref, port),
                        ),
                    ],
                    // Like a project in the Code sidebar: a heading over a hairline that folds what finished.
                    if (done.isNotEmpty) ...[
                      _DoneHeader(
                        count: done.length,
                        open: doneOpen,
                        onToggle: () => ref.read(processesDoneFoldedProvider.notifier).toggle(),
                      ),
                      AnimatedSize(
                        duration: Motion.reduced(context) ? Duration.zero : Motion.move,
                        curve: Motion.easeInOut,
                        alignment: Alignment.topCenter,
                        child: doneOpen
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [for (final g in done) shellRow(g)],
                              )
                            : const SizedBox(width: double.infinity),
                      ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

/// A shell and the processes running under it, with the ports they listen on.
@immutable
final class ShellGroup {
  const ShellGroup(this.shell, this.processes);
  final ShellEntry shell;

  /// Processes below the shell (not the shell itself).
  final List<SessionProcess> processes;

  List<ListeningPort> get ports {
    final byPort = {
      for (final p in processes)
        for (final l in p.ports) l.port: l,
    };
    return byPort.values.toList()..sort((a, b) => a.port.compareTo(b.port));
  }
}

/// [shells] with the [processes] under each (a dev server's workers sit under the shell that started them).
List<ShellGroup> groupByShell(List<ShellEntry> shells, List<SessionProcess> processes) {
  final parent = {for (final p in processes) p.pid: p.ppid};
  final roots = {
    for (final s in shells)
      if (s.running && s.pid != null) s.pid!: s,
  };
  final under = <String, List<SessionProcess>>{};
  for (final p in processes) {
    if (roots.containsKey(p.pid)) continue;
    var at = p.ppid;
    final seen = <int>{};
    while (seen.add(at)) {
      if (roots[at] case final s?) {
        (under[s.key] ??= []).add(p);
        break;
      }
      final up = parent[at];
      if (up == null) break;
      at = up;
    }
  }
  return [for (final s in shells) ShellGroup(s, under[s.key] ?? const [])];
}

/// The shells that finished (background jobs and foreground commands alike), the latest to end first.
List<ShellGroup> finishedShells(List<ShellGroup> groups) {
  final done = [
    for (final g in groups)
      if (!g.shell.running) g,
  ];
  return done..sort((a, b) => b.shell.endedAt!.compareTo(a.shell.endedAt!));
}

/// When a shell ended, short (`just now`, `4 min ago`, `2 h ago`), or null when it didn't.
String? _endedAgo(DateTime? at) {
  if (at == null) return null;
  final d = DateTime.now().difference(at);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

/// Whether the Processes tab's Done section is folded (Preferences `code.processes.done_folded`, every session).
final processesDoneFoldedProvider = NotifierProvider<ProcessesDoneFolded, bool>(ProcessesDoneFolded.new);

final class ProcessesDoneFolded extends Notifier<bool> {
  static const key = 'code.processes.done_folded';

  @override
  bool build() => ref.read(preferencesProvider)[key] == '1';

  void toggle() {
    state = !state;
    ref.read(preferencesProvider)[key] = state ? '1' : '0';
  }
}

/// The Done heading, styled like a project in the Code sidebar: name and count over a hairline, a chevron that folds
/// the finished shells below. Its insets match the shell rows', so the text lines up with their dots.
class _DoneHeader extends StatefulWidget {
  const _DoneHeader({required this.count, required this.open, required this.onToggle});

  final int count;
  final bool open;
  final VoidCallback onToggle;

  @override
  State<_DoneHeader> createState() => _DoneHeaderState();
}

class _DoneHeaderState extends State<_DoneHeader> {
  var _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final muted = _hover ? theme.textMuted : theme.textSubtle;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        key: const ValueKey('processes.done.header'),
        behavior: HitTestBehavior.opaque,
        onTap: widget.onToggle,
        child: Semantics(
          button: true,
          expanded: widget.open,
          label: 'Done',
          child: Container(
            margin: const EdgeInsets.fromLTRB(0, 14, 0, 4),
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 5),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: theme.border)),
            ),
            child: Row(
              children: [
                Text('Done', style: theme.type.caption.medium.tint(muted)),
                const SizedBox(width: 6),
                Text('${widget.count}', style: theme.type.caption.tint(theme.textSubtle)),
                const SizedBox(width: 4),
                AnimatedRotation(
                  turns: widget.open ? 0 : -0.25,
                  duration: Motion.reduced(context) ? Duration.zero : Motion.swap,
                  curve: Motion.easeInOut,
                  child: AdaptiveIcon(EveryIcon.chevronDown, size: 13, color: muted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The processes in no shell's group (the user's terminals, what an outside lead started).
List<SessionProcess> otherProcesses(List<ShellGroup> groups, List<SessionProcess> processes) {
  final taken = {
    for (final g in groups) ...[
      if (g.shell.running && g.shell.pid != null) g.shell.pid!,
      for (final p in g.processes) p.pid,
    ],
  };
  return [
    for (final p in processes)
      if (!taken.contains(p.pid)) p,
  ];
}

/// A shell: its title, who started it and how it is doing, the command, its ports, the processes under it. Click
/// opens its output in the drawer.
class _ShellRow extends StatefulWidget {
  const _ShellRow({
    required this.group,
    required this.onOpen,
    required this.onStop,
    required this.onRestart,
    required this.onPreview,
    required this.onStopChild,
  });

  final ShellGroup group;
  final VoidCallback onOpen;
  final VoidCallback? onStop;
  final Future<void> Function()? onRestart;
  final ValueChanged<ListeningPort> onPreview;
  final ValueChanged<SessionProcess> onStopChild;

  @override
  State<_ShellRow> createState() => _ShellRowState();
}

class _ShellRowState extends State<_ShellRow> {
  var _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final g = widget.group;
    final s = g.shell;
    final failed = !s.running && (s.exitCode ?? 0) != 0;
    final dot = s.running ? theme.success : (failed ? theme.danger : theme.textSubtle);
    final status = s.running
        ? (s.live?.interactive ?? false ? 'running · interactive' : 'running')
        : ['exited ${s.exitCode}', ?_endedAgo(s.endedAt)].join(' · ');
    final ports = g.ports;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onOpen,
        child: Container(
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 6),
          decoration: BoxDecoration(color: _hover ? theme.hover : null, borderRadius: BorderRadius.circular(8)),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 6, right: 8),
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            s.title,
                            overflow: TextOverflow.ellipsis,
                            style: theme.type.callout.semibold.tint(theme.text),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${s.id} · ${s.origin.label} · $status',
                          style: theme.type.caption.tint(failed ? theme.danger : theme.textMuted),
                        ),
                      ],
                    ),
                    if (s.description.trim().isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        s.command.trim(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: _mono.copyWith(color: theme.textMuted),
                      ),
                    ],
                    if (ports.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (final port in ports)
                            _PortChip(port: port, onTap: port.local ? () => widget.onPreview(port) : null),
                        ],
                      ),
                    ],
                    for (final p in g.processes)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '↳ ${p.name} ${p.pid}',
                          overflow: TextOverflow.ellipsis,
                          style: _mono.copyWith(color: theme.textSubtle),
                        ),
                      ),
                  ],
                ),
              ),
              AdaptiveMenuButton(
                tooltip: 'Shell actions',
                actions: [
                  MenuAction(label: 'Open output', onSelected: widget.onOpen),
                  if (widget.onStop case final stop?) MenuAction(label: 'Stop', onSelected: stop),
                  if (widget.onRestart case final restart?)
                    MenuAction(label: 'Restart', onSelected: () => unawaited(restart())),
                  for (final p in g.processes)
                    MenuAction(label: 'Stop ${p.name} (${p.pid})', onSelected: () => widget.onStopChild(p)),
                  MenuAction(
                    label: 'Copy command',
                    onSelected: () => Clipboard.setData(ClipboardData(text: s.command)),
                  ),
                ],
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(EveryIcon.more.of(theme.design), size: 16, color: theme.textMuted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProcessRow extends StatelessWidget {
  const _ProcessRow({
    required this.process,
    required this.onStop,
    required this.onForceQuit,
    required this.onPreview,
    this.onOpen,
  });

  final SessionProcess process;

  /// Shows its output (when it can be found).
  final VoidCallback? onOpen;
  final VoidCallback onStop;
  final VoidCallback onForceQuit;
  final ValueChanged<ListeningPort> onPreview;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final p = process;
    final ports = {for (final l in p.ports) l.port: l}.values.toList()..sort((a, b) => a.port.compareTo(b.port));
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        p.name,
                        overflow: TextOverflow.ellipsis,
                        style: theme.type.callout.semibold.tint(theme.text),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${p.pid} · ${p.origin == ProcessOrigin.agent ? 'agent' : 'terminal'}',
                      style: theme.type.caption.tint(theme.textMuted),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  p.command,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: _mono.copyWith(color: theme.textMuted),
                ),
                if (ports.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final port in ports) _PortChip(port: port, onTap: port.local ? () => onPreview(port) : null),
                    ],
                  ),
                ],
              ],
            ),
          ),
          AdaptiveMenuButton(
            tooltip: 'Process actions',
            actions: [
              if (onOpen case final open?) MenuAction(label: 'Show output', onSelected: open),
              MenuAction(label: 'Stop', onSelected: onStop),
              MenuAction(label: 'Force quit', destructive: true, onSelected: onForceQuit),
              MenuAction(
                label: 'Copy PID',
                onSelected: () => Clipboard.setData(ClipboardData(text: '${p.pid}')),
              ),
            ],
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(EveryIcon.more.of(theme.design), size: 16, color: theme.textMuted),
            ),
          ),
        ],
      ),
    );
    if (onOpen == null) return row;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onOpen,
      child: MouseRegion(cursor: SystemMouseCursors.click, child: row),
    );
  }
}

/// A container of the session: name, image, state and why it counts, its published ports. Click shows its logs.
class _ContainerRow extends StatelessWidget {
  const _ContainerRow({
    required this.container,
    required this.onLogs,
    required this.onShell,
    required this.onStop,
    required this.onPreview,
  });

  final SessionContainer container;
  final VoidCallback onLogs;
  final VoidCallback onShell;
  final VoidCallback onStop;
  final ValueChanged<ListeningPort> onPreview;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final c = container;
    final up = c.status == 'running';
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onLogs,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 6, right: 8),
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(color: up ? theme.cyan : theme.textSubtle, shape: BoxShape.circle),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            c.name,
                            overflow: TextOverflow.ellipsis,
                            style: theme.type.callout.semibold.tint(theme.text),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text('${c.cli} · ${c.status}', style: theme.type.caption.tint(theme.textMuted)),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${c.image} · ${c.why}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _mono.copyWith(color: theme.textMuted),
                    ),
                    if (c.ports.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (final port in c.ports)
                            _PortChip(port: port, onTap: port.local ? () => onPreview(port) : null),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              AdaptiveMenuButton(
                tooltip: 'Container actions',
                actions: [
                  MenuAction(label: 'Logs', onSelected: onLogs),
                  MenuAction(label: 'Shell inside', onSelected: onShell),
                  MenuAction(label: 'Stop', destructive: true, onSelected: onStop),
                  MenuAction(
                    label: 'Copy id',
                    onSelected: () => Clipboard.setData(ClipboardData(text: c.id)),
                  ),
                ],
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(EveryIcon.more.of(theme.design), size: 16, color: theme.textMuted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PortChip extends StatelessWidget {
  const _PortChip({required this.port, this.onTap});

  final ListeningPort port;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final label = port.local ? ':${port.port}' : '${port.host}:${port.port}';
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: theme.accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            onTap == null ? label : '$label  Preview',
            style: theme.type.footnote.mono.copyWith(color: theme.accent, height: 1.4),
          ),
        ),
      ),
    );
  }
}
