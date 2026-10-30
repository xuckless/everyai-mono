import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/router.dart';
import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../code_providers.dart';
import '../../domain/code_session.dart';
import '../../harness/harness.dart' show BackgroundTask;
import '../session_view.dart' show StatusPill;

/// What the session has going beside it: its forks and subagents (open,
/// steer, stop) and the commands it left running in the background.
class TasksPane extends ConsumerStatefulWidget {
  const TasksPane({super.key, required this.session});

  final CodeSessionInfo session;

  @override
  ConsumerState<TasksPane> createState() => _TasksPaneState();
}

class _TasksPaneState extends ConsumerState<TasksPane> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Background shells change without events; elapsed times move.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _steer(CodeSessionInfo child) async {
    final text = await showAdaptivePrompt(context, title: 'Message ${child.title}', confirmLabel: 'Send');
    if (text == null || text.trim().isEmpty) return;
    await ref.read(codeSessionProvider(child.id).notifier).steer(text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final children = ref.watch(
      codeSessionsProvider.select(
        (all) => [
          for (final s in all)
            if (s.parentId == widget.session.id) s,
        ],
      ),
    );
    final controller = ref.read(codeSessionProvider(widget.session.id).notifier);
    final shells = controller.backgroundTasks;
    if (children.isEmpty && shells.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Forks, subagents and commands the agent leaves running in the background show up here.',
            textAlign: TextAlign.center,
            style: theme.type.callout.tint(theme.textMuted),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      children: [
        if (children.isNotEmpty) _Header('Subagents and forks'),
        for (final child in children.reversed)
          _ChildRow(
            child: child,
            onOpen: () => context.push(Routes.codeSession(child.id)),
            onSteer: () => _steer(child),
            onStop: () => ref.read(codeSessionProvider(child.id).notifier).stop(),
          ),
        if (shells.isNotEmpty) _Header('Background commands'),
        for (final t in shells.reversed) _ShellRow(task: t, onStop: () => controller.stopBackground(t.id)),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
      child: Text(text, style: theme.type.caption.semibold.tint(theme.textMuted)),
    );
  }
}

String _elapsed(DateTime from) {
  final d = DateTime.now().difference(from);
  if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
  if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds % 60}s';
  return '${d.inSeconds}s';
}

class _ChildRow extends ConsumerWidget {
  const _ChildRow({required this.child, required this.onOpen, required this.onSteer, required this.onStop});

  final CodeSessionInfo child;
  final VoidCallback onOpen;
  final VoidCallback onSteer;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final status = ref.watch(codeSessionProvider(child.id).select((s) => s.status));
    final working = status == SessionStatus.running || status == SessionStatus.starting;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        border: Border.all(color: theme.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          StatusPill(status: status, dense: true),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  child.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.type.callout.tint(theme.text),
                ),
                Text(
                  '${status.label} · ${_elapsed(child.createdAt)}',
                  maxLines: 1,
                  style: theme.type.caption.tint(theme.textMuted),
                ),
              ],
            ),
          ),
          AdaptiveButton(label: 'Open', emphasis: ButtonEmphasis.plain, onPressed: onOpen),
          if (working) ...[
            AdaptiveButton(label: 'Steer', emphasis: ButtonEmphasis.plain, onPressed: onSteer),
            AdaptiveButton(label: 'Stop', emphasis: ButtonEmphasis.plain, onPressed: onStop),
          ],
        ],
      ),
    );
  }
}

class _ShellRow extends StatelessWidget {
  const _ShellRow({required this.task, required this.onStop});

  final BackgroundTask task;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        border: Border.all(color: theme.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task.description.isNotEmpty ? task.description : task.command,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.type.callout.tint(theme.text),
                ),
                Text(
                  '${task.id} · ${task.running ? 'running ${_elapsed(task.startedAt)}' : 'exited (${task.exitCode})'}',
                  maxLines: 1,
                  style: theme.type.caption.tint(task.running ? theme.textMuted : theme.textMuted),
                ),
              ],
            ),
          ),
          if (task.running) AdaptiveButton(label: 'Stop', emphasis: ButtonEmphasis.plain, onPressed: onStop),
        ],
      ),
    );
  }
}
