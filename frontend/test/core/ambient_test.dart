import 'package:every_ai/core/motion/ambient.dart';
import 'package:every_ai/core/motion/motion.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child, {bool reduced = false}) => MediaQuery(
  data: MediaQueryData(disableAnimations: reduced),
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: Center(child: child),
  ),
);

void main() {
  testWidgets('glow, ring and burst hold still without loops and settle', (tester) async {
    expect(Motion.ambient, isFalse, reason: 'tests run with ambient loops off');
    Widget card(int burst) => FinishBurst(
      trigger: burst == 0 ? null : burst,
      color: const Color(0xFF59D38C),
      child: BreathingRing(
        active: true,
        color: const Color(0xFFFFB020),
        child: GlowPulse(active: true, color: const Color(0xFF7756E4), child: const SizedBox(width: 200, height: 80)),
      ),
    );
    await tester.pumpWidget(_host(card(0)));
    await tester.pumpAndSettle();
    // A finish bursts once, then the sparks go.
    await tester.pumpWidget(_host(card(1)));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(CustomPaint), findsWidgets);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('one clock breathes for every card, only with loops on and something to breathe', (tester) async {
    addTearDown(() => Motion.ambient = false);
    Widget board({required bool running, bool reduced = false}) => _host(
      AmbientClock(
        running: running,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++)
              GlowPulse(active: true, color: const Color(0xFF7756E4), child: const SizedBox(width: 200, height: 40)),
            BreathingRing(active: true, color: const Color(0xFFFFB020), child: const SizedBox(width: 200, height: 40)),
          ],
        ),
      ),
      reduced: reduced,
    );

    // Loops off (as in every test): nothing ticks.
    await tester.pumpWidget(board(running: true));
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);

    Motion.ambient = true;
    // Loops on but nothing breathes: still nothing ticks.
    await tester.pumpWidget(board(running: false));
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    // Something breathes: one clock runs (one ticker for all four).
    await tester.pumpWidget(board(running: true));
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.binding.hasScheduledFrame, isTrue);
    expect(find.byType(FadeTransition), findsNWidgets(4));
    // Reduced motion stops it.
    await tester.pumpWidget(board(running: true, reduced: true));
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    Motion.ambient = false;
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a ticking count shows the new value; reduced motion swaps it at once', (tester) async {
    await tester.pumpWidget(_host(const TickingCount(2)));
    await tester.pumpWidget(_host(const TickingCount(3)));
    await tester.pumpAndSettle();
    expect(find.text('3'), findsOneWidget);
    expect(find.text('2'), findsNothing);

    await tester.pumpWidget(_host(const TickingCount(4), reduced: true));
    expect(find.text('4'), findsOneWidget);
  });

  testWidgets('no burst under reduced motion', (tester) async {
    Widget burst(int n) => _host(
      FinishBurst(trigger: n, color: const Color(0xFF59D38C), child: const SizedBox(width: 50, height: 50)),
      reduced: true,
    );
    await tester.pumpWidget(burst(1));
    await tester.pumpWidget(burst(2));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
