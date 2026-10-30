import 'package:flutter/widgets.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../domain/phases.dart';

/// Above the composer while a Max or Ultra flow runs: its phases, done ones
/// ticked, the current one lit; when stuck, how to move it on.
class PhaseStrip extends StatelessWidget {
  const PhaseStrip({super.key, required this.flow, required this.phase, this.stuck = false});

  final String flow;
  final Phase phase;
  final bool stuck;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final steps = Phase.values.where((p) => p != Phase.done).toList();
    final color = stuck ? theme.warning : theme.accent;
    return Semantics(
      label: '${flow == 'ultra' ? 'Ultra' : 'Max'} flow: ${phase.label}${stuck ? ', stuck' : ''}',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          border: Border.all(color: theme.border),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 6,
              runSpacing: 4,
              children: [
                Text(flow == 'ultra' ? 'Ultra' : 'Max', style: theme.type.caption.semibold.tint(color)),
                for (final (i, p) in steps.indexed) ...[
                  if (i > 0) AdaptiveIcon(EveryIcon.chevronRight, size: 9, color: theme.textMuted),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (p.index < phase.index) ...[
                        AdaptiveIcon(EveryIcon.check, size: 11, color: theme.textMuted),
                        const SizedBox(width: 3),
                      ],
                      Text(
                        p.label,
                        style: theme.type.caption.tint(
                          p == phase
                              ? color
                              : (p.index < phase.index ? theme.textMuted : theme.textMuted.withValues(alpha: 0.5)),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
            if (stuck)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Stuck here. Tell the agent what to do, run /skip-phase, or move to Thorough in the agent menu.',
                  style: theme.type.caption.tint(theme.textMuted),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
