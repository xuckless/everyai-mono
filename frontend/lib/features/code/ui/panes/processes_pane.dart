import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/every_icons.dart';
import '../../domain/code_session.dart';
import '../../domain/local_ports.dart';
import '../../panes/panes_providers.dart';
import '../../panes/processes.dart';

const _mono = TextStyle(fontFamily: 'SourceCodePro', fontSize: 11.5, height: 1.4);

/// What the session has running: the agent's background jobs and servers,
/// and what was started from the Terminal pane, with their ports.
class ProcessesPane extends ConsumerWidget {
  const ProcessesPane({super.key, required this.session});

  final CodeSessionInfo session;

  void _kill(BuildContext context, WidgetRef ref, SessionProcess p, {bool force = false}) {
    final ok = killProcess(p.pid, force: force);
    showAdaptiveToast(context, ok ? '${force ? 'Killed' : 'Stopped'} ${p.name} (${p.pid})' : "Couldn't stop ${p.pid}");
    ref.invalidate(sessionProcessesProvider(session.id));
  }

  void _preview(WidgetRef ref, ListeningPort port) {
    ref.read(previewUrlProvider(session.id).notifier).set(urlForPort(port.port));
    ref.read(codePaneProvider(session.id).notifier).show(CodePane.preview);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final snapshot = ref.watch(sessionProcessesProvider(session.id));
    final list = snapshot.value ?? const <SessionProcess>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  snapshot.isLoading && snapshot.value == null
                      ? 'Looking…'
                      : '${list.length} running · ${list.fold(0, (n, p) => n + p.ports.length)} listening',
                  style: TextStyle(color: theme.textMuted, fontSize: 12),
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
          child: list.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Nothing running. Servers and background jobs the agent or the terminal starts show here.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: theme.textMuted, fontSize: 13),
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                  itemCount: list.length,
                  separatorBuilder: (_, _) => Container(height: 1, color: theme.border),
                  itemBuilder: (context, i) => _ProcessRow(
                    process: list[i],
                    onStop: () => _kill(context, ref, list[i]),
                    onForceQuit: () => _kill(context, ref, list[i], force: true),
                    onPreview: (port) => _preview(ref, port),
                  ),
                ),
        ),
      ],
    );
  }
}

class _ProcessRow extends StatelessWidget {
  const _ProcessRow({required this.process, required this.onStop, required this.onForceQuit, required this.onPreview});

  final SessionProcess process;
  final VoidCallback onStop;
  final VoidCallback onForceQuit;
  final ValueChanged<ListeningPort> onPreview;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final p = process;
    final ports = {for (final l in p.ports) l.port: l}.values.toList()..sort((a, b) => a.port.compareTo(b.port));
    return Padding(
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
                        style: TextStyle(color: theme.text, fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${p.pid} · ${p.origin == ProcessOrigin.agent ? 'agent' : 'terminal'}',
                      style: TextStyle(color: theme.textMuted, fontSize: 11.5),
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
            style: _mono.copyWith(color: theme.accent, fontSize: 11),
          ),
        ),
      ),
    );
  }
}
