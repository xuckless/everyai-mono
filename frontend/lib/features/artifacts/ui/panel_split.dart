import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/every_theme.dart';
import '../artifact_providers.dart';

/// The chat and the artifact panel side by side, split by a divider the user
/// can drag (double-click resets it). The width is remembered across chats
/// and restarts ([artifactPanelWidthProvider]).
class PanelSplit extends ConsumerStatefulWidget {
  const PanelSplit({super.key, required this.maxWidth, required this.child, required this.panel});

  /// The width available to both sides.
  final double maxWidth;
  final Widget child;
  final Widget panel;

  /// The narrowest either side may get.
  static const minSide = 360.0;

  /// The panel's width for [saved] (null: the default share) in [maxWidth].
  static double widthFor(double? saved, double maxWidth) {
    final upper = (maxWidth - minSide).clamp(minSide, double.infinity);
    return (saved ?? (maxWidth * 0.52).clamp(minSide, 780.0)).clamp(minSide, upper);
  }

  @override
  ConsumerState<PanelSplit> createState() => _PanelSplitState();
}

class _PanelSplitState extends ConsumerState<PanelSplit> {
  bool _hover = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final width = PanelSplit.widthFor(ref.watch(artifactPanelWidthProvider), widget.maxWidth);
    final store = ref.read(artifactPanelWidthProvider.notifier);
    final active = _hover || _dragging;
    return Row(
      children: [
        Expanded(child: widget.child),
        MouseRegion(
          cursor: SystemMouseCursors.resizeColumn,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            key: const ValueKey('panel-divider'),
            behavior: HitTestBehavior.opaque,
            dragStartBehavior: DragStartBehavior.down,
            onHorizontalDragStart: (_) => setState(() => _dragging = true),
            onHorizontalDragUpdate: (d) {
              // Read the latest width: several updates can arrive between frames.
              final current = PanelSplit.widthFor(ref.read(artifactPanelWidthProvider), widget.maxWidth);
              store.set(PanelSplit.widthFor(current - d.delta.dx, widget.maxWidth), persist: false);
            },
            onHorizontalDragEnd: (_) {
              setState(() => _dragging = false);
              store.set(ref.read(artifactPanelWidthProvider) ?? width);
            },
            onDoubleTap: () => store.set(null),
            child: SizedBox(
              width: 6,
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  // At rest the panel's own left border is the divider line.
                  width: 3,
                  color: active ? theme.accent.withValues(alpha: 0.6) : const Color(0x00000000),
                ),
              ),
            ),
          ),
        ),
        SizedBox(width: width, child: widget.panel),
      ],
    );
  }
}
