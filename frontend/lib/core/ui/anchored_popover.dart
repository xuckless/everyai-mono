import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../motion/motion.dart';
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
  State<AnchoredPopover> createState() => AnchoredPopoverState();
}

class AnchoredPopoverState extends State<AnchoredPopover> with SingleTickerProviderStateMixin {
  static const _radius = 14.0;

  final _portal = OverlayPortalController();
  late final _anim = AnimationController(vsync: this, duration: Motion.popIn, reverseDuration: Motion.popOut);

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  bool get isOpen => _portal.isShowing && _anim.status != AnimationStatus.reverse;

  /// Opens the panel as if the trigger were tapped (`/model` opens the picker).
  void open() {
    if (!mounted) return;
    setState(() => _closing = false);
    _portal.show();
    _anim.forward();
  }

  /// A closing panel lets taps through while it animates out.
  bool _closing = false;

  /// Closes toward the trigger, then removes the panel.
  void close() {
    if (!_portal.isShowing) return;
    setState(() => _closing = true);
    _anim.reverse().whenComplete(() {
      if (mounted && _anim.isDismissed) _portal.hide();
    });
  }

  void _toggle() => isOpen ? close() : open();

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: _buildPanel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggle,
        child: MouseRegion(cursor: SystemMouseCursors.click, child: widget.child),
      ),
    );
  }

  Widget _buildPanel(BuildContext overlayContext) {
    final box = context.findRenderObject()! as RenderBox;
    // Placed from the trigger's rect in the overlay, not by following its
    // layer: a trigger that fades out once the pointer leaves its row
    // (Opacity 0 isn't painted) would drop the panel at the window's corner.
    final overlay = Overlay.maybeOf(context)?.context.findRenderObject() as RenderBox?;
    final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
    // Read either way: a window resize rebuilds the panel at the new spot.
    final screen = MediaQuery.sizeOf(overlayContext);
    final window = overlay != null && overlay.hasSize ? overlay.size : screen;
    final padding = MediaQuery.paddingOf(overlayContext);
    // The on-screen keyboard (phones) covers the bottom of the window.
    final bottom = window.height - MediaQuery.viewInsetsOf(overlayContext).bottom;
    final alignRight = origin.dx + box.size.width / 2 > window.width / 2;
    final openUp = origin.dy + box.size.height / 2 > bottom / 2;
    final roomVertical = openUp
        ? origin.dy - padding.top - 12
        : bottom - padding.bottom - origin.dy - box.size.height - 12;

    // Keep the panel inside the window on narrow screens: cap its width, then
    // shift it sideways when the trigger's edge leaves too little room.
    const margin = 8.0;
    final maxWidth = (widget.width ?? 360).clamp(0.0, window.width - 2 * margin);
    final minWidth = (widget.width ?? 200).clamp(0.0, maxWidth);
    final double dx;
    if (alignRight) {
      // Right edges line up; move right when the left edge would cross the margin.
      final right = origin.dx + box.size.width;
      dx = math.min(math.max(0.0, margin + maxWidth - right), window.width - margin - right);
    } else {
      // Left edges line up; move left when the right edge would cross the margin.
      final left = origin.dx;
      dx = math.max(math.min(0.0, window.width - margin - maxWidth - left), margin - left);
    }

    return IgnorePointer(
      ignoring: _closing,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: close),
          ),
          Positioned(
            left: alignRight ? null : origin.dx + dx,
            right: alignRight ? window.width - (origin.dx + box.size.width + dx) : null,
            top: openUp ? null : origin.dy + box.size.height + 6,
            bottom: openUp ? window.height - origin.dy + 6 : null,
            child: CallbackShortcuts(
              bindings: {const SingleActivator(LogicalKeyboardKey.escape): close},
              child: FocusScope(
                autofocus: true,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minWidth: minWidth,
                    maxWidth: maxWidth,
                    maxHeight: roomVertical.clamp(120, widget.maxHeight),
                  ),
                  child: _PopTransition(
                    animation: _anim,
                    // Grow from the corner nearest the trigger.
                    alignment: Alignment(alignRight ? 0.8 : -0.8, openUp ? 1 : -1),
                    child: GlassSurface(
                      level: GlassLevel.thick,
                      radius: _radius,
                      child: widget.builder(overlayContext, close),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Popover entrance: fade and scale from 0.95 (ease-out); the exit runs the
/// same path back with an ease-in, 20% faster.
class _PopTransition extends StatelessWidget {
  const _PopTransition({required this.animation, required this.alignment, required this.child});
  final Animation<double> animation;
  final Alignment alignment;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: animation, curve: Motion.easeOut, reverseCurve: Motion.easeExit);
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(
        alignment: alignment,
        scale: Tween(begin: Motion.popoverStartScale, end: 1.0).animate(curved),
        child: child,
      ),
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
  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final enabled = widget.onTap != null;
    final touch = Host.isMobile;
    final titleColor = !enabled
        ? theme.textSubtle
        : widget.destructive
        ? theme.danger
        : theme.text;
    return Pressable(
      onTap: widget.onTap,
      selected: widget.selected,
      builder: (context, s, child) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 0.5),
        constraints: BoxConstraints(minHeight: touch ? 44 : 34),
        padding: EdgeInsets.symmetric(horizontal: 10, vertical: widget.subtitle == null ? 6 : 7),
        decoration: BoxDecoration(
          color: s.pressed
              ? theme.pressed
              : s.hovered
              ? theme.hover
              : null,
          borderRadius: BorderRadius.circular(9),
        ),
        child: child,
      ),
      child: Row(
        children: [
          if (widget.leading != null) ...[widget.leading!, const SizedBox(width: 10)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(widget.title, style: (touch ? theme.type.body : theme.type.callout).tint(titleColor)),
                if (widget.subtitle != null) Text(widget.subtitle!, style: theme.type.caption.tint(theme.textSubtle)),
              ],
            ),
          ),
          if (widget.trailing != null) ...[const SizedBox(width: 8), widget.trailing!],
        ],
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
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(label, style: theme.type.caption.medium.tint(theme.textSubtle)),
    );
  }
}
