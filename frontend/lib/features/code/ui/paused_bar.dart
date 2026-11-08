// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/widgets.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../domain/fork_state.dart';

/// Above the composer while the session holds after a Pause (see [StepHold]): what holds, and Resume.
class PausedBar extends StatelessWidget {
  const PausedBar({super.key, required this.hold, required this.onResume});

  final StepHold hold;
  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final text = hold == StepHold.pausing
        ? 'Pausing: each agent ends the step it is on.'
        : 'Paused. Nothing new starts; shells and servers keep running.';
    return Padding(
      key: const ValueKey('paused-bar'),
      padding: const EdgeInsets.only(bottom: 6),
      child: KitCard(
        padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
        color: theme.overlay,
        radius: 10,
        child: Row(
          children: [
            AdaptiveIcon(EveryIcon.pause, size: 13, color: theme.textMuted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.type.caption.tint(theme.text),
              ),
            ),
            AdaptiveButton(
              key: const ValueKey('paused-bar.resume'),
              label: 'Resume',
              emphasis: ButtonEmphasis.plain,
              onPressed: onResume,
            ),
          ],
        ),
      ),
    );
  }
}
