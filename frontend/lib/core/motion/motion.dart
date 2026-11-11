import 'dart:ui' show ImageFilter;

import 'package:flutter/widgets.dart';

/// The owner's motion rules, in one place. Every animated thing in the app
/// takes its curve and duration from here.
///
/// - Entrances ease out; moves ease in and out; nothing bounces on everyday UI.
/// - Dropdowns and popovers run 150-250ms, start at 0.95 and grow from their
///   trigger; they exit back toward it, 20% faster than they came in.
/// - List rows stagger by 30ms and details settle (fade, a few px, a little blur).
/// - Old and new states overlap (crossfade in one stack), icons crossfade with blur.
/// - Pressed controls scale to 0.97 and stay there while held.
/// - Switch knobs stretch 12% while moving; objects travel on arcs; reveals use masks;
///   success pulses; scroll and drags rubber-band past their bounds.
abstract final class Motion {
  static const easeOut = Cubic(0.23, 1, 0.32, 1);
  static const easeInOut = Cubic(0.65, 0, 0.35, 1);
  static const easeExit = Cubic(0.4, 0, 1, 1);

  /// Popovers, dropdowns, menus.
  static const popIn = Duration(milliseconds: 200);
  static const popOut = Duration(milliseconds: 160);

  /// Sheets and drawers (phone).
  static const sheetIn = Duration(milliseconds: 320);
  static const sheetOut = Duration(milliseconds: 256);

  /// Press feedback.
  static const press = Duration(milliseconds: 140);

  /// Indicators and other moving parts.
  static const move = Duration(milliseconds: 280);

  /// Crossfades between two states.
  static const swap = Duration(milliseconds: 240);
  static const iconSwap = Duration(milliseconds: 200);

  /// Rows entering one after another.
  static const stagger = Duration(milliseconds: 30);
  static const rowIn = Duration(milliseconds: 260);
  static const settle = Duration(milliseconds: 340);

  static const pulse = Duration(milliseconds: 700);

  /// One slow breath (back and forth) of the ambient glow and ring, and how often it is redrawn: a breath this slow
  /// needs no more than ~15 frames a second.
  static const breath = Duration(milliseconds: 2800);
  static const breathTick = Duration(milliseconds: 66);

  /// The sparks of a finish.
  static const burst = Duration(milliseconds: 820);
  static const pressedScale = 0.97;
  static const popoverStartScale = 0.95;
  static const knobStretch = 0.12;

  /// An exit is 20% shorter than its entrance.
  static Duration exitOf(Duration entrance) => entrance * 0.8;

  /// The delay of row [index] in a staggered list.
  static Duration staggerAt(int index, {Duration base = Duration.zero}) => base + stagger * index;

  /// The user asked the OS for less motion.
  static bool reduced(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// Endless ambient loops (breathing dots, shimmer, spinners). Tests turn
  /// them off so `pumpAndSettle` can settle.
  static bool ambient = true;

  /// Ambient loops run unless reduced motion or [ambient] says otherwise.
  static bool loops(BuildContext context) => ambient && !reduced(context);

  /// Resistance past a bound: [overshoot] px of drag gives at most [limit] px of travel.
  static double rubberBand(double overshoot, {double limit = 90, double k = 0.55}) {
    if (overshoot <= 0) return 0;
    return (1 - 1 / (overshoot * k / limit + 1)) * limit;
  }
}

/// Entrance helpers. Delays are part of one controller's timeline (no timers),
/// so staggered rows cost nothing to cancel and tests can settle them.
extension MotionEntrances on Widget {
  /// A list row arriving: fade and 5px up, 260ms ease-out, staggered by [index].
  Widget rowIn(int index, {Duration base = Duration.zero, Key? key}) => Entrance(
    key: key,
    delay: Motion.staggerAt(index, base: base),
    duration: Motion.rowIn,
    rise: 5,
    child: this,
  );

  /// A detail settling into place: fade, 3px up and a 3px blur clearing.
  Widget settle({Duration delay = Duration.zero, Key? key}) =>
      Entrance(key: key, delay: delay, duration: Motion.settle, rise: 3, blur: 3, child: this);
}

/// Plays once when first built: fade in, rise by [rise] px and clear a [blur],
/// after [delay], with the ease-out curve.
class Entrance extends StatefulWidget {
  const Entrance({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = Motion.rowIn,
    this.rise = 5,
    this.blur = 0,
  });

  final Widget child;
  final Duration delay;
  final Duration duration;
  final double rise;
  final double blur;

  @override
  State<Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<Entrance> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _t;

  @override
  void initState() {
    super.initState();
    final total = widget.delay + widget.duration;
    _c = AnimationController(vsync: this, duration: total);
    final start = total.inMicroseconds == 0 ? 0.0 : widget.delay.inMicroseconds / total.inMicroseconds;
    _t = CurvedAnimation(
      parent: _c,
      curve: Interval(start, 1, curve: Motion.easeOut),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_c.isDismissed) Motion.reduced(context) ? _c.value = 1 : _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _t,
    child: widget.child,
    builder: (context, child) {
      final t = _t.value;
      if (t >= 1) return child!;
      final b = widget.blur * (1 - t);
      Widget out = Transform.translate(offset: Offset(0, widget.rise * (1 - t)), child: child);
      if (b > 0.05) {
        out = ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: b, sigmaY: b),
          child: out,
        );
      }
      return Opacity(opacity: t, child: out);
    },
  );
}

/// Scales its child to 0.97 while pressed (fast ease-out down, held without
/// tweening, eased back on release) and reports hover for hover fills.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.builder,
    this.cursor,
    this.scale = true,
    this.semanticLabel,
    this.selected,
    this.focusNode,
    this.behavior = HitTestBehavior.opaque,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Builds a decoration around [child] from the hover/press state.
  final Widget Function(BuildContext context, PressState state, Widget child)? builder;
  final MouseCursor? cursor;
  final bool scale;
  final String? semanticLabel;
  final bool? selected;
  final FocusNode? focusNode;
  final HitTestBehavior behavior;

  @override
  State<Pressable> createState() => _PressableState();
}

@immutable
final class PressState {
  const PressState({required this.hovered, required this.pressed, required this.focused, required this.enabled});
  final bool hovered;
  final bool pressed;
  final bool focused;
  final bool enabled;
}

class _PressableState extends State<Pressable> {
  bool _hover = false;
  bool _down = false;
  bool _focus = false;

  bool get _enabled => widget.onTap != null || widget.onLongPress != null;

  void _setDown(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final state = PressState(
      hovered: _hover && _enabled,
      pressed: _down && _enabled,
      focused: _focus,
      enabled: _enabled,
    );
    var child = widget.builder?.call(context, state, widget.child) ?? widget.child;
    if (widget.scale) {
      child = AnimatedScale(
        scale: state.pressed ? Motion.pressedScale : 1,
        duration: Motion.press,
        curve: Motion.easeOut,
        child: child,
      );
    }
    return Semantics(
      button: _enabled,
      enabled: _enabled,
      selected: widget.selected,
      label: widget.semanticLabel,
      child: FocusableActionDetector(
        enabled: _enabled,
        focusNode: widget.focusNode,
        mouseCursor: widget.cursor ?? (_enabled ? SystemMouseCursors.click : MouseCursor.defer),
        onShowHoverHighlight: (v) => setState(() => _hover = v),
        onShowFocusHighlight: (v) => setState(() => _focus = v),
        actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => widget.onTap?.call())},
        child: GestureDetector(
          behavior: widget.behavior,
          onTapDown: _enabled ? (_) => _setDown(true) : null,
          onTapUp: _enabled ? (_) => _setDown(false) : null,
          onTapCancel: () => _setDown(false),
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          child: child,
        ),
      ),
    );
  }
}

/// Crossfades two or more states in one stack, so the old and new overlap
/// (240ms ease-in-out, a 4px drift and a 2px blur on the leaving one).
class StateSwap extends StatelessWidget {
  const StateSwap({super.key, required this.child, this.duration = Motion.swap, this.alignment = Alignment.topLeft});

  /// Give each state its own key.
  final Widget child;
  final Duration duration;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: duration,
    reverseDuration: duration,
    switchInCurve: Motion.easeInOut,
    switchOutCurve: Motion.easeInOut,
    layoutBuilder: (current, previous) => Stack(alignment: alignment, children: [...previous, ?current]),
    transitionBuilder: (child, animation) => AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final t = animation.value;
        return Opacity(
          opacity: t.clamp(0, 1),
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 4),
            child: t >= 0.999
                ? child
                : ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: (1 - t) * 2, sigmaY: (1 - t) * 2),
                    child: child,
                  ),
          ),
        );
      },
    ),
    child: child,
  );
}

/// Crossfades icons with a blur and a scale from 0.5 (copy → check, send → stop).
class IconSwap extends StatelessWidget {
  const IconSwap({super.key, required this.child});

  /// Give each icon its own key.
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: Motion.iconSwap,
    switchInCurve: Motion.easeOut,
    switchOutCurve: Motion.easeOut,
    layoutBuilder: (current, previous) => Stack(alignment: Alignment.center, children: [...previous, ?current]),
    transitionBuilder: (child, animation) => AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final t = animation.value;
        final blur = (1 - t) * 4;
        return Opacity(
          opacity: t.clamp(0, 1),
          child: Transform.scale(
            scale: 0.5 + 0.5 * t,
            child: blur < 0.05
                ? child
                : ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                    child: child,
                  ),
          ),
        );
      },
    ),
    child: child,
  );
}

/// A ring that expands and fades from the child's shape to confirm success.
/// Bump [trigger] to fire it.
class SuccessPulse extends StatefulWidget {
  const SuccessPulse({
    super.key,
    required this.trigger,
    required this.child,
    this.color,
    this.radius = 999,
    this.spread = 12,
  });

  final Object? trigger;
  final Widget child;
  final Color? color;
  final double radius;
  final double spread;

  @override
  State<SuccessPulse> createState() => _SuccessPulseState();
}

class _SuccessPulseState extends State<SuccessPulse> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: Motion.pulse);

  @override
  void didUpdateWidget(SuccessPulse old) {
    super.didUpdateWidget(old);
    if (widget.trigger != old.trigger && widget.trigger != null && !Motion.reduced(context)) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? const Color(0xFF59D38C);
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) {
        if (!_c.isAnimating) return child!;
        final t = Motion.easeOut.transform(_c.value);
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.55 * (1 - t)),
                spreadRadius: widget.spread * t,
              ),
            ],
          ),
          child: child,
        );
      },
    );
  }
}

/// Reveals its child with a mask: from the top edge down ([axis] vertical) or
/// from the leading edge across (horizontal), 300ms ease-out.
class MaskReveal extends StatelessWidget {
  const MaskReveal({
    super.key,
    required this.child,
    this.axis = Axis.vertical,
    this.delay = Duration.zero,
    this.duration = const Duration(milliseconds: 300),
  });

  final Widget child;
  final Axis axis;
  final Duration delay;
  final Duration duration;

  @override
  Widget build(BuildContext context) => _Progress(
    delay: delay,
    duration: duration,
    builder: (t) => ClipRect(clipper: _RevealClipper(t, axis), child: child),
  );
}

/// Runs 0→1 once over [delay] + [duration] (ease-out after the delay).
class _Progress extends StatefulWidget {
  const _Progress({required this.delay, required this.duration, required this.builder});
  final Duration delay;
  final Duration duration;
  final Widget Function(double t) builder;

  @override
  State<_Progress> createState() => _ProgressState();
}

class _ProgressState extends State<_Progress> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: widget.delay + widget.duration);
  late final Animation<double> _t = CurvedAnimation(
    parent: _c,
    curve: Interval(
      (widget.delay + widget.duration).inMicroseconds == 0
          ? 0
          : widget.delay.inMicroseconds / (widget.delay + widget.duration).inMicroseconds,
      1,
      curve: Motion.easeOut,
    ),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_c.isDismissed) Motion.reduced(context) ? _c.value = 1 : _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      AnimatedBuilder(animation: _t, builder: (context, _) => widget.builder(_t.value));
}

class _RevealClipper extends CustomClipper<Rect> {
  const _RevealClipper(this.t, this.axis);
  final double t;
  final Axis axis;

  @override
  Rect getClip(Size size) => axis == Axis.vertical
      ? Rect.fromLTWH(0, 0, size.width, size.height * t)
      : Rect.fromLTWH(0, 0, size.width * t, size.height);

  @override
  bool shouldReclip(_RevealClipper old) => old.t != t || old.axis != axis;
}

/// Grows a colour across [child] with a mask from the leading edge (a button
/// filling green when its action succeeds).
class MaskFill extends StatelessWidget {
  const MaskFill({super.key, required this.filled, required this.color, required this.child, this.radius = 9});

  final bool filled;
  final Color color;
  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(end: filled ? 1 : 0),
    duration: const Duration(milliseconds: 300),
    curve: Motion.easeOut,
    builder: (context, t, child) => Stack(
      children: [
        if (t > 0)
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(radius),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                widthFactor: 1,
                child: FractionallySizedBox(
                  widthFactor: t,
                  heightFactor: 1,
                  child: ColoredBox(color: color),
                ),
              ),
            ),
          ),
        child!,
      ],
    ),
    child: child,
  );
}

/// Flies a small dot along an arc from [from] to [to] in the overlay (a lane
/// moving to the Board). X and Y run on different curves, which bends the path.
void flyAlongArc(
  BuildContext context, {
  required Offset from,
  required Offset to,
  required Color color,
  VoidCallback? onArrive,
}) {
  final overlay = Overlay.maybeOf(context);
  if (overlay == null || Motion.reduced(context)) {
    onArrive?.call();
    return;
  }
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _ArcDot(
      from: from,
      to: to,
      color: color,
      onDone: () {
        entry.remove();
        onArrive?.call();
      },
    ),
  );
  overlay.insert(entry);
}

class _ArcDot extends StatefulWidget {
  const _ArcDot({required this.from, required this.to, required this.color, required this.onDone});
  final Offset from;
  final Offset to;
  final Color color;
  final VoidCallback onDone;

  @override
  State<_ArcDot> createState() => _ArcDotState();
}

class _ArcDotState extends State<_ArcDot> with SingleTickerProviderStateMixin {
  static const _x = Cubic(0.45, 0, 0.75, 0.2);
  static const _y = Cubic(0.2, 0.9, 0.3, 1);
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 640))
    ..forward().whenComplete(widget.onDone);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value;
        final x = widget.from.dx + (widget.to.dx - widget.from.dx) * _x.transform(t);
        final y = widget.from.dy + (widget.to.dy - widget.from.dy) * _y.transform(t);
        final fade = t < 0.85 ? 1.0 : 1 - (t - 0.85) / 0.15;
        final scale = 1 - 0.4 * t;
        return Stack(
          children: [
            Positioned(
              left: x - 5,
              top: y - 5,
              child: Opacity(
                opacity: fade.clamp(0, 1),
                child: Transform.scale(
                  scale: scale,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: widget.color,
                      shape: BoxShape.circle,
                      boxShadow: [BoxShadow(color: widget.color.withValues(alpha: 0.25), spreadRadius: 4)],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}

/// Rubber-band scrolling on every platform, with no overscroll glow.
class EveryScrollBehavior extends ScrollBehavior {
  const EveryScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(parent: RangeMaintainingScrollPhysics());

  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) => child;
}

/// A spring with no overshoot, for drags that settle back (sheets).
const settleSpring = SpringDescription(mass: 1, stiffness: 420, damping: 2 * 20.5);
