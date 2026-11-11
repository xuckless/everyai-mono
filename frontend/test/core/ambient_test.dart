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
