import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/router.dart';
import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/brand.dart';
import '../../../../core/ui/every_icons.dart';
import '../../../chat/ui/chat_markdown.dart';
import '../../code_providers.dart';
import '../../domain/code_session.dart';
import '../../domain/subagents.dart';
import '../../domain/transcript.dart';
import 'transcript_items.dart' show SubagentView;

/// A subagent the agent started with `run_subagent`, as a nested card: what it was
/// asked, how it is doing, and its report once it hands one back. "Open"
/// shows the child's own transcript (where its approvals wait).
class SubagentCard extends ConsumerWidget {
  const SubagentCard({super.key, required this.item});
  final SubagentItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // OpenHands' own delegation, in sessions from before `run_subagent` existed.
    if (!item.ours) return SubagentView(item: item);
    final theme = EveryTheme.of(context);
    final callId = item.step.call.id;
    final child = ref.watch(
      codeSessionsProvider.select((all) => all.where((s) => s.parentCallId == callId).firstOrNull),
    );
    // Finished children aren't reconnected just to draw the card.
    final childState = child == null || item.report != null ? null : ref.watch(codeSessionProvider(child.id));
    final report = item.report;
    final steps = childState == null ? 0 : stepCount(childState.transcript);
    final status = _status(report, childState?.status);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.border),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (report == null)
                const EveryMarkActivity(activity: MarkActivity.tool, size: 14)
              else
                AdaptiveIcon(EveryIcon.spark, size: 14, color: theme.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  item.task.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.type.callout.semibold.tint(theme.text),
                ),
              ),
              Text(
                [status, if (steps > 0) '$steps ${steps == 1 ? 'step' : 'steps'}'].join(' · '),
                style: theme.type.caption.tint(
                  childState?.status == SessionStatus.needsInput && report == null ? theme.warning : theme.textMuted,
                ),
              ),
              if (child != null) ...[
                const SizedBox(width: 8),
                AdaptiveButton(
                  label: 'Open',
                  emphasis: ButtonEmphasis.plain,
                  onPressed: () => context.push(Routes.codeSession(child.id)),
                ),
              ],
            ],
          ),
          if (item.task.agent.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 22),
              child: Text('Role: ${item.task.agent}', style: theme.type.caption.tint(theme.textMuted)),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 22),
            child: _Fold(
              title: 'Instructions',
              child: Text(item.task.prompt, style: theme.type.callout.tint(theme.textMuted)),
            ),
          ),
          if (report != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 22),
              child: _Fold(
                title: 'Report',
                initiallyOpen: report.status != SubagentStatus.completed,
                child: ChatMarkdown(report.text.isEmpty ? '(no report)' : report.text),
              ),
            ),
        ],
      ),
    );
  }

  static String _status(SubagentReport? report, SessionStatus? child) => switch (report?.status) {
    SubagentStatus.completed => 'Done',
    SubagentStatus.failed => 'Failed',
    SubagentStatus.stopped => 'Stopped',
    SubagentStatus.notStarted => 'Not started',
    null => switch (child) {
      null || SessionStatus.starting => 'Starting',
      SessionStatus.needsInput => 'Needs your approval',
      SessionStatus.done || SessionStatus.idle => 'Reporting',
      SessionStatus.failed => 'Failed',
      SessionStatus.running => 'Working',
    },
  };
}

/// A tappable title that shows [child] when open.
class _Fold extends StatefulWidget {
  const _Fold({required this.title, required this.child, this.initiallyOpen = false});
  final String title;
  final Widget child;
  final bool initiallyOpen;

  @override
  State<_Fold> createState() => _FoldState();
}

class _FoldState extends State<_Fold> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _open = !_open),
            child: Semantics(
              button: true,
              expanded: _open,
              child: Row(
                children: [
                  AnimatedRotation(
                    turns: _open ? 0 : -0.25,
                    duration: const Duration(milliseconds: 150),
                    child: AdaptiveIcon(EveryIcon.chevronDown, size: 12, color: theme.textMuted),
                  ),
                  const SizedBox(width: 4),
                  Text(widget.title, style: theme.type.callout.tint(theme.textMuted)),
                ],
              ),
            ),
          ),
        ),
        if (_open) Padding(padding: const EdgeInsets.only(top: 4, left: 16), child: widget.child),
      ],
    );
  }
}
