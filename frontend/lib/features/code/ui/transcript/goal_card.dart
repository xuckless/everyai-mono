import 'package:flutter/widgets.dart';

import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/brand.dart';
import '../../../../core/ui/every_icons.dart';
import '../../domain/goal.dart';

/// The session's `/goal` above the composer: the objective, where the loop
/// is, and the judge's latest reason.
class GoalCard extends StatelessWidget {
  const GoalCard({super.key, required this.goal, required this.onClear});

  final Goal goal;

  /// Stops the loop (while it runs) or dismisses the card (once it settled).
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final color = switch (goal.status) {
      GoalStatus.met => theme.success,
      GoalStatus.outOfTurns || GoalStatus.paused => theme.danger,
      _ => theme.textMuted,
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
              if (goal.status == GoalStatus.checking) ...[
                const EveryMarkActivity(activity: MarkActivity.thinking, size: 13),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(
                  'Goal · ${goal.statusLabel}',
                  style: TextStyle(color: color, fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
              ),
              AdaptiveIconButton(
                icon: EveryIcon.close,
                tooltip: goal.status.settled ? 'Dismiss' : 'Stop the goal',
                size: 14,
                onPressed: onClear,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Text(
              goal.objective,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
          ),
          if (goal.note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 6),
              child: Text(goal.note, style: TextStyle(color: theme.textMuted, fontSize: 12)),
            ),
        ],
      ),
    );
  }
}
