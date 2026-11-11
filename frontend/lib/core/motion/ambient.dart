import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/widgets.dart';

import 'motion.dart';

// Calm ambient effects for live things: a breathing glow while something works, a ring while it waits on the user,
// a small burst when it finishes, trails behind moving cards and numbers that tick. Endless loops run only while
// [Motion.loops] allows (never under reduced motion, nor in tests); one-shot effects are skipped under reduced motion.

/// A soft glow around [child] in [color] while [active]: it breathes slowly (2.8 s) while loops run, and holds a
/// faint steady glow otherwise. [strength] scales it (1 for something working, less for something waiting).
class GlowPulse extends StatefulWidget {
  const GlowPulse({
    super.key,
    required this.active,
    required this.color,
    required this.child,
    this.radius = 16,
    this.strength = 1,
  });

  final bool active;
  final Color color;
  final double radius;
  final double strength;
  final Widget child;

  @override
  State<GlowPulse> createState() => _GlowPulseState();
}

class _GlowPulseState extends State<GlowPulse> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2800));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(GlowPulse old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final run = widget.active && Motion.loops(context);
    if (run && !_c.isAnimating) _c.repeat(reverse: true);
    if (!run && _c.isAnimating) _c.stop();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  BoxDecoration _glow(double t) => BoxDecoration(
    borderRadius: BorderRadius.circular(widget.radius),
    boxShadow: [
      BoxShadow(
        color: widget.color.withValues(alpha: (0.10 + 0.12 * t) * widget.strength),
        blurRadius: 14 + 10 * t,
        spreadRadius: -2 + 2 * t,
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return widget.child;
    if (!_c.isAnimating) return DecoratedBox(decoration: _glow(0.4), child: widget.child);
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) => DecoratedBox(decoration: _glow(Motion.easeInOut.transform(_c.value)), child: child),
    );
  }
}

/// A thin ring around [child] that breathes in [color] while [active] (something waits on the user); a steady ring
/// when loops are off.
class BreathingRing extends StatefulWidget {
  const BreathingRing({super.key, required this.active, required this.color, required this.child, this.radius = 16});

  final bool active;
  final Color color;
  final double radius;
  final Widget child;

  @override
  State<BreathingRing> createState() => _BreathingRingState();
}

class _BreathingRingState extends State<BreathingRing> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1700));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(BreathingRing old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final run = widget.active && Motion.loops(context);
    if (run && !_c.isAnimating) _c.repeat(reverse: true);
    if (!run && _c.isAnimating) _c.stop();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return widget.child;
    Widget ring(double t) => DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.radius),
        border: Border.all(color: widget.color.withValues(alpha: 0.35 + 0.4 * t), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: widget.color.withValues(alpha: 0.12 * t),
            blurRadius: 4 + 8 * t,
          ),
        ],
      ),
      child: widget.child,
    );
    if (!_c.isAnimating) return ring(0.5);
    return AnimatedBuilder(animation: _c, builder: (context, _) => ring(Motion.easeInOut.transform(_c.value)));
  }
}

/// A small burst of sparks from [child]'s centre whenever [trigger] changes (a session finished). Nothing under
/// reduced motion.
class FinishBurst extends StatefulWidget {
  const FinishBurst({super.key, required this.trigger, required this.color, required this.child, this.sparks = 14});

  final Object? trigger;
  final Color color;
  final int sparks;
  final Widget child;

  @override
  State<FinishBurst> createState() => _FinishBurstState();
}

class _FinishBurstState extends State<FinishBurst> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 820));

  /// A new seed per burst, so two bursts don't look the same.
  var _seed = 0;

  @override
  void didUpdateWidget(FinishBurst old) {
    super.didUpdateWidget(old);
    if (widget.trigger != old.trigger && widget.trigger != null && !Motion.reduced(context)) {
      _seed++;
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    child: widget.child,
    builder: (context, child) {
      if (!_c.isAnimating) return child!;
      return CustomPaint(
        foregroundPainter: SparkPainter(t: _c.value, color: widget.color, count: widget.sparks, seed: _seed),
        child: child,
      );
    },
  );
}

/// Sparks flying out from the centre at time [t] (0–1), fading as they go.
class SparkPainter extends CustomPainter {
  SparkPainter({required this.t, required this.color, required this.count, required this.seed});

  final double t;
  final Color color;
  final int count;
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final rnd = math.Random(seed);
    final centre = size.center(Offset.zero);
    final reach = size.shortestSide * 0.5 + 18;
    final ease = Motion.easeOut.transform(t);
    for (var i = 0; i < count; i++) {
      final angle = (i / count) * math.pi * 2 + rnd.nextDouble() * 0.5;
      final dist = reach * (0.55 + rnd.nextDouble() * 0.45) * ease;
      final p = centre + Offset(math.cos(angle) * dist, math.sin(angle) * dist * 0.6);
      final paint = Paint()..color = color.withValues(alpha: (1 - t) * 0.8);
      canvas.drawCircle(p, lerpDouble(2.2, 0.6, t)!, paint);
    }
  }

  @override
  bool shouldRepaint(SparkPainter old) => old.t != t || old.seed != seed || old.color != color;
}

/// A soft streak behind a moving card: from [from] (where it was a moment ago) to [to] (where it is), relative to the
/// card's resting place, fading toward its tail.
class TrailPainter extends CustomPainter {
  TrailPainter({required this.from, required this.to, required this.color, required this.opacity});

  final Offset from;
  final Offset to;
  final Color color;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0 || (to - from).distance < 2) return;
    final c = size.center(Offset.zero);
    final head = c + to;
    final tail = c + from;
    final paint = Paint()
      ..shader = LinearGradient(
        colors: [
          color.withValues(alpha: 0),
          color.withValues(alpha: 0.35 * opacity),
        ],
      ).createShader(Rect.fromPoints(tail, head))
      ..strokeWidth = math.min(size.height * 0.5, 18)
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
    canvas.drawLine(tail, head, paint);
  }

  @override
  bool shouldRepaint(TrailPainter old) =>
      old.from != from || old.to != to || old.opacity != opacity || old.color != color;
}

/// A number that ticks: the old value slides up and out while the new one comes in from below.
class TickingCount extends StatelessWidget {
  const TickingCount(this.value, {super.key, this.style});

  final int value;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final text = Text('$value', key: ValueKey(value), style: style);
    if (Motion.reduced(context)) return text;
    return ClipRect(
      child: AnimatedSwitcher(
        duration: Motion.swap,
        switchInCurve: Motion.easeOut,
        switchOutCurve: Motion.easeExit,
        transitionBuilder: (child, a) {
          final incoming = child.key == ValueKey(value);
          return SlideTransition(
            position: Tween(begin: Offset(0, incoming ? 0.7 : -0.7), end: Offset.zero).animate(a),
            child: FadeTransition(opacity: a, child: child),
          );
        },
        layoutBuilder: (current, previous) => Stack(alignment: Alignment.center, children: [...previous, ?current]),
        child: text,
      ),
    );
  }
}

/// Rebuilds [builder] every [period] (elapsed times, "no progress for N min"). The clock stops in tests
/// ([Motion.ambient] off) so they can settle; reduced motion keeps it, as it moves text, not things.
class PeriodicRebuild extends StatefulWidget {
  const PeriodicRebuild({super.key, required this.period, required this.builder});

  final Duration period;
  final WidgetBuilder builder;

  @override
  State<PeriodicRebuild> createState() => _PeriodicRebuildState();
}

class _PeriodicRebuildState extends State<PeriodicRebuild> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (Motion.ambient) _timer = Timer.periodic(widget.period, (_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
