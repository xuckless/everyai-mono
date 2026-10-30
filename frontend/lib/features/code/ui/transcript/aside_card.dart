import 'package:flutter/widgets.dart';

import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/brand.dart';
import '../../../../core/ui/every_icons.dart';
import '../../../chat/ui/chat_markdown.dart';
import '../../../usage/ui/usage_meter.dart';
import '../../../usage/usage_totals.dart';
import '../../domain/session_commands.dart';

/// A `/btw` answer or `/cost` breakdown above the composer. It sits outside
/// the transcript: the agent never sees it.
class AsideCard extends StatelessWidget {
  const AsideCard({
    super.key,
    required this.aside,
    required this.onDismiss,
    this.usage = UsageTotals.zero,
    this.contextWindow = 0,
    this.modelName,
  });

  final Aside aside;
  final VoidCallback onDismiss;

  /// For a cost card.
  final UsageTotals usage;
  final int contextWindow;
  final String? modelName;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final title = switch (aside.kind) {
      AsideKind.btw => 'By the way: ${aside.question}',
      AsideKind.cost => 'Session usage',
    };
    final Widget body = switch (aside) {
      Aside(kind: AsideKind.cost) =>
        usage.isEmpty
            ? Text('No model calls yet.', style: TextStyle(color: theme.textMuted, fontSize: 13))
            : UsageBreakdown(totals: usage, contextWindow: contextWindow, modelName: modelName),
      Aside(busy: true) => Row(
        children: [
          const EveryMarkActivity(activity: MarkActivity.thinking, size: 14),
          const SizedBox(width: 8),
          Text('Thinking…', style: TextStyle(color: theme.textMuted, fontSize: 13)),
        ],
      ),
      Aside(:final error?) => Text(error, style: TextStyle(color: theme.danger, fontSize: 13)),
      Aside(:final answer) => ChatMarkdown(answer),
    };
    return Container(
      decoration: BoxDecoration(
        color: theme.accent.withValues(alpha: 0.06),
        border: Border.all(color: theme.border),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: theme.textMuted, fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
              ),
              AdaptiveIconButton(icon: EveryIcon.close, tooltip: 'Dismiss', size: 14, onPressed: onDismiss),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: SingleChildScrollView(child: body),
            ),
          ),
        ],
      ),
    );
  }
}
