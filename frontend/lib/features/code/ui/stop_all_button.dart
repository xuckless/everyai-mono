// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' as m show Tooltip;

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../domain/session_work.dart';

/// A small up-chevron beside Send/Stop (the composer) or a card's controls (the Board) that opens one row: Stop
/// all, which stops the lead's turn, its background forks and its workflows. Built only while [work] has something
/// besides the lead's turn ([hasSideWork]).
///
/// No state of its own: [work] and [leadBusy] are read by its parent as it builds, and the menu is the kit's.
class StopAllButton extends StatelessWidget {
  const StopAllButton({super.key, required this.work, required this.leadBusy, required this.onStopAll, this.size = 32});

  final SessionWork work;
  final bool leadBusy;
  final VoidCallback onStopAll;

  /// The round trigger's size: the composer's Send is 32; a Board card's header uses 22.
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return m.Tooltip(
      message: 'Stop all',
      child: AdaptiveMenuButton(
        tooltip: 'Stop all',
        width: 300,
        actions: [
          MenuAction(
            label: 'Stop all · ${stopAllScope(work, leadBusy: leadBusy)}',
            icon: EveryIcon.stop,
            destructive: true,
            onSelected: onStopAll,
          ),
        ],
        child: Container(
          key: const ValueKey('stop-all'),
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: theme.overlay,
            border: Border.all(color: theme.border),
          ),
          child: Icon(EveryIcon.chevronUp.data, size: size * 0.5, color: theme.textMuted),
        ),
      ),
    );
  }
}
