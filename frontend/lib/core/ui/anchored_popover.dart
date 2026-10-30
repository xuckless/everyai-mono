import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../platform/platform_kind.dart';
import '../theme/every_theme.dart';
import 'adaptive.dart';

/// A panel anchored to its trigger: the model picker, the composer's + menu,
/// macOS menus. Opens toward the side of the window with room (right-aligned in
/// the right half, upward in the lower part), dismisses on outside tap or Escape.
class AnchoredPopover extends StatefulWidget {
  const AnchoredPopover({super.key, required this.builder, required this.child, this.width, this.maxHeight = 480});

  /// Builds the panel content. Call `close` after a selection.
  final Widget Function(BuildContext context, VoidCallback close) builder;

  /// The trigger. Tapping it toggles the panel.
  final Widget child;
  final double? width;
  final double maxHeight;

  @override
  State<AnchoredPopover> createState() => _AnchoredPopoverState();
}

class _AnchoredPopoverState extends State<AnchoredPopover> {
  /// Popovers follow the brand's control radius, but stay native-tight on Fluent.
  static double _radius(EveryTheme theme) => theme.design == DesignLanguage.fluent ? 8 : 14;

  final _portal = OverlayPortalController();
  final _link = LayerLink();

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: _buildPanel,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _portal.toggle,
          child: MouseRegion(cursor: SystemMouseCursors.click, child: widget.child),
        ),
      ),
    );
  }

  Widget _buildPanel(BuildContext overlayContext) {
    final theme = EveryTheme.of(context);
    final box = context.findRenderObject()! as RenderBox;
    final origin = box.localToGlobal(Offset.zero);
    final window = MediaQuery.sizeOf(overlayContext);
    final alignRight = origin.dx + box.size.width / 2 > window.width / 2;
    final openUp = origin.dy + box.size.height / 2 > window.height / 2;
    final roomVertical = openUp ? origin.dy - 12 : window.height - origin.dy - box.size.height - 12;

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: _portal.hide),
        ),
        Positioned(
          left: 0,
          top: 0,
          child: CompositedTransformFollower(
            link: _link,
            targetAnchor: Alignment(alignRight ? 1 : -1, openUp ? -1 : 1),
            followerAnchor: Alignment(alignRight ? 1 : -1, openUp ? 1 : -1),
            offset: Offset(0, openUp ? -6 : 6),
            child: CallbackShortcuts(
              bindings: {const SingleActivator(LogicalKeyboardKey.escape): _portal.hide},
              child: FocusScope(
                autofocus: true,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minWidth: widget.width ?? 200,
                    maxWidth: widget.width ?? 360,
                    maxHeight: roomVertical.clamp(120, widget.maxHeight),
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(_radius(theme)),
                      boxShadow: const [BoxShadow(color: Color(0x80000000), blurRadius: 48, offset: Offset(0, 24))],
                    ),
                    child: GlassSurface(
                      level: GlassLevel.thick,
                      radius: _radius(theme),
                      child: widget.builder(overlayContext, _portal.hide),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// One row inside an [AnchoredPopover] list: hover highlight, optional leading,
/// title, subtitle and trailing check.
class PopoverRow extends StatefulWidget {
  const PopoverRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.selected = false,
    this.destructive = false,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool selected;
  final bool destructive;

  @override
  State<PopoverRow> createState() => _PopoverRowState();
}

class _PopoverRowState extends State<PopoverRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final enabled = widget.onTap != null;
    final titleColor = !enabled
        ? theme.textMuted
        : widget.destructive
        ? theme.danger
        : theme.text;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Semantics(
          button: true,
          selected: widget.selected,
          enabled: enabled,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: _hover && enabled ? theme.text.withValues(alpha: 0.07) : null,
              borderRadius: BorderRadius.circular(theme.radius - 2),
            ),
            child: Row(
              children: [
                if (widget.leading != null) ...[widget.leading!, const SizedBox(width: 10)],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(widget.title, style: theme.type.body.tint(titleColor)),
                      if (widget.subtitle != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Text(widget.subtitle!, style: theme.type.caption.tint(theme.textMuted)),
                        ),
                    ],
                  ),
                ),
                if (widget.trailing != null) ...[const SizedBox(width: 8), widget.trailing!],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Small uppercase-free group label inside a popover.
class PopoverHeader extends StatelessWidget {
  const PopoverHeader(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Text(label, style: theme.type.caption.medium.tint(theme.textMuted)),
    );
  }
}
