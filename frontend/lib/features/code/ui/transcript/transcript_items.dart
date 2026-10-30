import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/every_icons.dart';
import '../../../attachments/attachment.dart';
import '../../../attachments/ui/attachment_tray.dart';
import '../../../chat/ui/chat_markdown.dart';
import '../../domain/agent_mode.dart';
import '../../domain/line_diff.dart';
import '../../domain/transcript.dart';
import '../../harness/events.dart';
import '../../uploads/uploads.dart';

const _mono = TextStyle(fontFamily: 'SourceCodePro', fontSize: 12.5, height: 1.45);

/// The user's message, right-aligned like chat.
class UserTurnView extends StatelessWidget {
  const UserTurnView({super.key, required this.text, this.mode, this.onRewind});
  final String text;

  /// Restores the files to before this message.
  final VoidCallback? onRewind;

  /// The mode the message was sent in, when it told the agent about one.
  final AgentMode? mode;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final (body, files) = splitAttachedNote(text);
    return Align(
      alignment: Alignment.centerRight,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (mode case final mode?)
            Padding(
              padding: const EdgeInsets.only(bottom: 4, right: 4),
              child: Text(
                '${mode.label} mode',
                style: TextStyle(color: theme.textMuted, fontSize: 11.5, fontWeight: FontWeight.w500),
              ),
            ),
          if (files.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final path in files)
                    AttachmentChip(name: path.split('/').last, kind: kindOf(path, Uint8List(0))),
                ],
              ),
            ),
          if (body.trim().isNotEmpty)
            LayoutBuilder(
              builder: (context, constraints) => ConstrainedBox(
                constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.85),
                child: DecoratedBox(
                  decoration: BoxDecoration(color: theme.userBubble, borderRadius: theme.userBubbleShape),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                    child: IntrinsicWidth(child: ChatMarkdown(body, textColor: theme.onUserBubble)),
                  ),
                ),
              ),
            ),
          if (onRewind case final rewind?)
            GestureDetector(
              onTap: rewind,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Padding(
                  padding: const EdgeInsets.only(top: 4, right: 4),
                  child: Text('Restore files to here', style: TextStyle(color: theme.textMuted, fontSize: 11.5)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The agent's prose, with its reasoning folded away.
class AgentTextView extends StatelessWidget {
  const AgentTextView({super.key, required this.text, this.reasoning = '', this.streaming = false});
  final String text;
  final String reasoning;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (reasoning.trim().isNotEmpty)
          _Disclosure(
            icon: EveryIcon.spark,
            title: streaming && text.isEmpty ? 'Thinking…' : 'Thought',
            child: Text(reasoning.trim(), style: TextStyle(color: EveryTheme.of(context).textMuted, fontSize: 13)),
          ),
        if (text.trim().isNotEmpty) ChatMarkdown(text, streaming: streaming),
      ],
    );
  }
}

/// "Explored 2 files, 1 search", expandable to each step.
class ExploreGroupView extends StatelessWidget {
  const ExploreGroupView({super.key, required this.group});
  final ExploreGroup group;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final running = group.steps.any((s) => !s.done);
    return _Disclosure(
      icon: EveryIcon.search,
      title: '${running ? 'Exploring' : 'Explored'} ${exploreSummary(group.steps)}',
      busy: running,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final s in group.steps)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  _StatusDot(step: s),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      stepTitle(s.call),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _mono.copyWith(color: theme.textMuted),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A command, an edit or another tool call.
class StepView extends StatelessWidget {
  const StepView({super.key, required this.step});
  final ToolStep step;

  @override
  Widget build(BuildContext context) => switch (step.call.actionKind) {
    'TerminalAction' => _CommandView(step: step),
    'FileEditorAction' || 'EditAction' || 'WriteFileAction' => _EditView(step: step),
    _ => _Disclosure(
      icon: EveryIcon.code,
      title: stepTitle(step.call),
      trailing: _StatusDot(step: step),
      child: _Output(step.result?.text ?? ''),
    ),
  };
}

class _CommandView extends StatelessWidget {
  const _CommandView({required this.step});
  final ToolStep step;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final obs = step.result?.observation ?? const {};
    final exit = obs['exit_code'] as int? ?? (obs['metadata'] as Map<String, Object?>?)?['exit_code'] as int?;
    final output = step.result?.text ?? (step.rejected ? 'Not run: ${step.result!.observation['reason'] ?? ''}' : '');
    return _Disclosure(
      title: '\$ ${step.call.str('command')}',
      titleStyle: _mono.copyWith(color: theme.text),
      busy: !step.done,
      initiallyOpen: false,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (exit != null && exit != 0) Text('exit $exit', style: TextStyle(color: theme.danger, fontSize: 11.5)),
          const SizedBox(width: 6),
          _StatusDot(step: step),
        ],
      ),
      child: _Output(output),
    );
  }
}

class _EditView extends StatelessWidget {
  const _EditView({required this.step});
  final ToolStep step;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final call = step.call;
    final obs = step.result?.observation ?? const {};
    final before = obs['old_content'] as String? ?? call.str('old_str');
    final after =
        obs['new_content'] as String? ?? (call.str('new_str').isNotEmpty ? call.str('new_str') : call.str('file_text'));
    final lines = lineDiff(before, after);
    final stats = diffStats(lines);
    return _Disclosure(
      // Folded while waiting (the approval card shows the diff); opens once applied.
      key: ValueKey(step.done),
      icon: EveryIcon.edit,
      title: stepTitle(call),
      busy: !step.done,
      initiallyOpen: step.done && !step.rejected,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (stats.added > 0) Text('+${stats.added}', style: TextStyle(color: theme.success, fontSize: 12)),
          const SizedBox(width: 4),
          if (stats.removed > 0) Text('−${stats.removed}', style: TextStyle(color: theme.danger, fontSize: 12)),
          const SizedBox(width: 6),
          _StatusDot(step: step),
        ],
      ),
      child: step.rejected ? _Output('Not applied: ${obs['reason'] ?? 'rejected'}') : DiffBlock(lines: lines),
    );
  }
}

/// A unified diff with line numbers.
class DiffBlock extends StatelessWidget {
  const DiffBlock({super.key, required this.lines, this.maxLines = 60});
  final List<DiffLine> lines;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    if (lines.isEmpty) return Text('No changes', style: TextStyle(color: theme.textMuted, fontSize: 12.5));
    final shown = lines.take(maxLines).toList();
    return Container(
      decoration: BoxDecoration(color: theme.codeBackground, borderRadius: BorderRadius.circular(8)),
      clipBehavior: Clip.antiAlias,
      // Rows fill the block (or the longest line) so highlights span it.
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: IntrinsicWidth(child: _rows(theme, shown)),
          ),
        ),
      ),
    );
  }

  Widget _rows(EveryTheme theme, List<DiffLine> shown) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final l in shown)
        Container(
          color: switch (l.kind) {
            DiffKind.added => theme.success.withValues(alpha: 0.14),
            DiffKind.removed => theme.danger.withValues(alpha: 0.13),
            _ => null,
          },
          padding: const EdgeInsets.only(right: 16),
          child: l.kind == DiffKind.gap
              ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                  child: Text('⋯ ${l.text}', style: _mono.copyWith(color: theme.textMuted, fontSize: 11.5)),
                )
              : Row(
                  children: [
                    SizedBox(
                      width: 36,
                      child: Text(
                        '${l.newNo ?? l.oldNo ?? ''}',
                        textAlign: TextAlign.right,
                        style: _mono.copyWith(color: theme.textMuted.withValues(alpha: 0.7), fontSize: 11.5),
                      ),
                    ),
                    SizedBox(
                      width: 18,
                      child: Text(switch (l.kind) {
                        DiffKind.added => ' +',
                        DiffKind.removed => ' −',
                        _ => '',
                      }, style: _mono.copyWith(color: l.kind == DiffKind.added ? theme.success : theme.danger)),
                    ),
                    Text(l.text, style: _mono.copyWith(color: theme.text)),
                  ],
                ),
        ),
      if (lines.length > maxLines)
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            '${lines.length - maxLines} more lines in the Diff pane',
            style: TextStyle(color: theme.textMuted, fontSize: 12),
          ),
        ),
    ],
  );
}

/// A delegated task, as a nested card.
class SubagentView extends StatelessWidget {
  const SubagentView({super.key, required this.item});
  final SubagentItem item;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final step = item.step;
    final tasks = item.tasks;
    final names = tasks.keys.isEmpty ? ['subagent'] : tasks.keys.toList();
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
              AdaptiveIcon(EveryIcon.spark, size: 14, color: theme.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  step.done ? 'Subagent ${names.join(', ')} finished' : 'Subagent ${names.join(', ')} working…',
                  style: TextStyle(color: theme.text, fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              _StatusDot(step: step),
            ],
          ),
          for (final e in tasks.entries)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 22),
              child: Text(e.value, style: TextStyle(color: theme.textMuted, fontSize: 12.5)),
            ),
          if (step.result case final r?)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 22),
              child: _Disclosure(title: 'Result', child: ChatMarkdown(r.text.isEmpty ? '(no output)' : r.text)),
            ),
        ],
      ),
    );
  }
}

/// The agent's task list.
class PlanView extends StatelessWidget {
  const PlanView({super.key, required this.tasks, this.compact = false});
  final List<PlanTask> tasks;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final done = tasks.where((t) => t.status == 'done').length;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: theme.surfaceRaised,
        border: Border.all(color: theme.border),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Plan · $done of ${tasks.length} done',
            style: TextStyle(color: theme.textMuted, fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          for (final t in tasks)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(padding: const EdgeInsets.only(top: 2), child: _TaskMark(t.status)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      t.title,
                      style: TextStyle(
                        color: t.status == 'done' ? theme.textMuted : theme.text,
                        fontSize: 13,
                        fontWeight: t.status == 'in_progress' ? FontWeight.w600 : FontWeight.w400,
                        decoration: t.status == 'done' ? TextDecoration.lineThrough : null,
                        decorationColor: theme.textMuted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _TaskMark extends StatelessWidget {
  const _TaskMark(this.status);
  final String status;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return switch (status) {
      'done' => Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(color: theme.success, shape: BoxShape.circle),
        child: Center(child: AdaptiveIcon(EveryIcon.check, size: 10, color: const Color(0xFFFFFFFF))),
      ),
      'in_progress' => Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          border: Border.all(color: theme.accent, width: 2),
          shape: BoxShape.circle,
        ),
        child: Center(
          child: Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(color: theme.accent, shape: BoxShape.circle),
          ),
        ),
      ),
      _ => Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          border: Border.all(color: theme.textMuted, width: 1.5),
          shape: BoxShape.circle,
        ),
      ),
    };
  }
}

class NoticeView extends StatelessWidget {
  const NoticeView({super.key, required this.item});
  final NoticeItem item;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final color = item.error ? theme.danger : theme.textMuted;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8)),
      child: Text(item.message, style: TextStyle(color: color, fontSize: 13)),
    );
  }
}

/// Spinner while running, check when done, cross on failure.
class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.step});
  final ToolStep step;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    if (!step.done) return const SizedBox.square(dimension: 12, child: AdaptiveProgress());
    if (step.rejected) return AdaptiveIcon(EveryIcon.close, size: 13, color: theme.textMuted);
    if (step.failed) return AdaptiveIcon(EveryIcon.close, size: 13, color: theme.danger);
    return AdaptiveIcon(EveryIcon.check, size: 13, color: theme.success);
  }
}

class _Output extends StatelessWidget {
  const _Output(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    if (text.trim().isEmpty) return Text('No output', style: TextStyle(color: theme.textMuted, fontSize: 12.5));
    final lines = text.split('\n');
    final clipped = lines.length > 40 ? [...lines.take(40), '… ${lines.length - 40} more lines'].join('\n') : text;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: theme.codeBackground, borderRadius: BorderRadius.circular(8)),
      child: Text(clipped, style: _mono.copyWith(color: theme.text)),
    );
  }
}

/// A one-line header that expands to [child].
class _Disclosure extends StatefulWidget {
  const _Disclosure({
    super.key,
    required this.title,
    required this.child,
    this.icon,
    this.trailing,
    this.titleStyle,
    this.busy = false,
    this.initiallyOpen = false,
  });

  final String title;
  final Widget child;
  final EveryIcon? icon;
  final Widget? trailing;
  final TextStyle? titleStyle;
  final bool busy;
  final bool initiallyOpen;

  @override
  State<_Disclosure> createState() => _DisclosureState();
}

class _DisclosureState extends State<_Disclosure> {
  late bool _open = widget.initiallyOpen;
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _open = !_open),
            child: Semantics(
              button: true,
              expanded: _open,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                decoration: BoxDecoration(
                  color: _hover ? theme.text.withValues(alpha: 0.04) : null,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    if (widget.icon != null) ...[
                      AdaptiveIcon(widget.icon!, size: 13, color: theme.textMuted),
                      const SizedBox(width: 8),
                    ],
                    // Title and chevron hug the left; trailing sits at the right edge.
                    Expanded(
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              widget.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: widget.titleStyle ?? TextStyle(color: theme.textMuted, fontSize: 13),
                            ),
                          ),
                          const SizedBox(width: 4),
                          AnimatedRotation(
                            turns: _open ? 0.25 : 0,
                            duration: const Duration(milliseconds: 120),
                            child: AdaptiveIcon(EveryIcon.chevronRight, size: 11, color: theme.textMuted),
                          ),
                        ],
                      ),
                    ),
                    if (widget.trailing != null) widget.trailing!,
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_open) Padding(padding: const EdgeInsets.fromLTRB(6, 4, 0, 4), child: widget.child),
      ],
    );
  }
}

/// Describes an action waiting for approval.
String approvalTitle(ActionCall call) => switch (call.actionKind) {
  'TerminalAction' => 'Run this command?',
  'FileEditorAction' when call.str('command') == 'view' => 'Read ${call.str('path')}?',
  'FileEditorAction' when call.str('command') == 'create' => 'Create ${call.str('path')}?',
  'FileEditorAction' => 'Edit ${call.str('path')}?',
  'DelegateAction' || 'TaskAction' => 'Start a subagent?',
  _ => 'Allow ${call.toolName}?',
};
