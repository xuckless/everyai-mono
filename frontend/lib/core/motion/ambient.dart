import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/widgets.dart';

import 'motion.dart';

// Calm ambient effects for live things: a breathing glow while something works, a ring while it waits on the user,
// a small burst when it finishes, trails behind moving cards and numbers that tick. Endless loops run only while
// [Motion.loops] allows (never under reduced motion, nor in tests); one-shot effects are skipped under reduced motion.
//
// Every effect keeps one widget structure whether it shows or not (an idle glow is a layer at zero opacity, an idle
// burst a painter that is null), so switching an effect on or off never rebuilds what it wraps: the card under it
// keeps its state.

/// One slow breathing clock (2.8 s, back and forth) for every [GlowPulse] and [BreathingRing] under it, so a board of
/// cards runs one ticker instead of one per card. It runs only while [running] (something on screen breathes) and
/// [Motion.loops] allows; otherwise the effects under it hold still.
class AmbientClock extends StatefulWidget {
  const AmbientClock({super.key, required this.running, required this.child});

  final bool running;
  final Widget child;

  /// The clock above [context] while it runs, else null (the effects then hold a steady value).
  static Animation<double>? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_AmbientScope>()?.clock;

  @override
  State<AmbientClock> createState() => _AmbientClockState();
}

class _AmbientClockState extends State<AmbientClock> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2800));

  /// Whether it runs: the scope below hands the clock out only then.
  bool _on = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(AmbientClock old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final run = widget.running && Motion.loops(context);
    if (run == _on) return;
    _on = run;
    if (run) {
      _c.repeat(reverse: true);
    } else {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _AmbientScope(clock: _on ? _c : null, child: widget.child);
}

class _AmbientScope extends InheritedWidget {
  const _AmbientScope({required this.clock, required super.child});

  final Animation<double>? clock;

  @override
  bool updateShouldNotify(_AmbientScope old) => old.clock != clock;
}

/// [clock] eased and mapped from [low] to [high]; [steady] when there is no clock running.
Animation<double> _breath(
  Animation<double>? clock, {
  required double low,
  required double high,
  required double steady,
}) => clock == null
    ? AlwaysStoppedAnimation(steady)
    : clock.drive(CurveTween(curve: Motion.easeInOut)).drive(Tween(begin: low, end: high));

/// A soft glow around [child] in [color] while [active]: it breathes with the [AmbientClock] above it, and holds a
/// faint steady glow without one. [strength] scales it (1 for something working, less for something waiting). The
/// glow is a fixed blur whose opacity moves, so a breath repaints nothing: neither the blur nor [child] (kept behind
/// a [RepaintBoundary]).
class GlowPulse extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final opacity = active
        ? _breath(AmbientClock.of(context), low: 0.45 * strength, high: strength, steady: 0.7 * strength)
        : const AlwaysStoppedAnimation(0.0);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: FadeTransition(
              opacity: opacity,
              child: RepaintBoundary(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(radius),
                    boxShadow: [BoxShadow(color: color.withValues(alpha: 0.22), blurRadius: 22, spreadRadius: -1)],
                  ),
                ),
              ),
            ),
          ),
        ),
        RepaintBoundary(child: child),
      ],
    );
  }
}

/// A thin ring around [child] that breathes in [color] while [active] (something waits on the user), with the
/// [AmbientClock] above it; a steady ring without one. Like [GlowPulse], only the ring's opacity moves.
class BreathingRing extends StatelessWidget {
  const BreathingRing({super.key, required this.active, required this.color, required this.child, this.radius = 16});

  final bool active;
  final Color color;
  final double radius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final opacity = active
        ? _breath(AmbientClock.of(context), low: 0.45, high: 1, steady: 0.75)
        : const AlwaysStoppedAnimation(0.0);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned.fill(
          child: IgnorePointer(
            child: FadeTransition(
              opacity: opacity,
              child: RepaintBoundary(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(radius),
                    border: Border.all(color: color.withValues(alpha: 0.75), width: 1.2),
                    boxShadow: [BoxShadow(color: color.withValues(alpha: 0.12), blurRadius: 10)],
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

/// A small burst of sparks from [child]'s centre whenever [trigger] changes (a session finished). Nothing under
/// reduced motion. [child] is always under the same painter (null when no burst shows), so a burst never rebuilds it.
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
    builder: (context, child) => CustomPaint(
      foregroundPainter: _c.isAnimating
          ? SparkPainter(t: _c.value, color: widget.color, count: widget.sparks, seed: _seed)
          : null,
      child: child,
    ),
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
