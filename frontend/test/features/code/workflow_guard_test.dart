import 'package:every_ai/features/code/harness/events.dart' show PlanWindow;
import 'package:every_ai/features/code/workflows/workflow_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dollars: rows at 50% and 80% once each, past the ceiling every time, and Continue raises it by half', () {
    final g = GuardMarks(ceilingMicros: 2000000);
    expect(g.spend(900000), isEmpty);
    expect(g.spend(1000000).map((e) => e.text), ['50% of the estimate used (\$1.00 of \$2.00)']);
    expect(g.spend(1100000), isEmpty);
    final at80 = g.spend(1700000);
    expect(at80.single, isA<GuardMark>());
    expect(at80.single.text, startsWith('80%'));
    expect(g.spend(2000000).single, isA<GuardOver>());
    expect(g.spend(2100000).single, isA<GuardOver>(), reason: 'still over: a resume asks again');
    g.raise(spentMicros: 2100000);
    expect(g.ceilingMicros, 3000000);
    expect(g.spend(2100000), isEmpty, reason: '70% of the new ceiling: its 50% counts as passed');
    expect(g.spend(2400000).single.text, startsWith('80% of the estimate used (\$2.40 of \$3.00)'));
    expect(g.passed, containsAll(['spend50@2000000', 'spend80@2000000', 'spend80@3000000']));
  });

  test('no ceiling, no dollar marks; passed marks from the journal are not repeated', () {
    expect(GuardMarks().spend(99000000), isEmpty);
    final g = GuardMarks(ceilingMicros: 1000000, passed: {'spend50@1000000'});
    expect(g.spend(600000), isEmpty);
  });

  test('plan windows: rows at 50%, 80% and 90% of what was left at the start; never over', () {
    final g = GuardMarks(windowsAtStart: {'five_hour': 0.4});
    String label(PlanWindow w) => w.name;
    const w = 'five_hour';
    expect(g.windows([const PlanWindow(name: w, used: 0.6)], label), isEmpty);
    // 0.4 + 0.6 * 0.5 = 0.7
    expect(g.windows([const PlanWindow(name: w, used: 0.7)], label).single.text, contains('50% of what was left'));
    final late = g.windows([const PlanWindow(name: w, used: 0.97)], label);
    expect(late.map((e) => e.id), ['limit:five_hour:80', 'limit:five_hour:90']);
    expect(late.every((e) => e is GuardMark), isTrue);
    // A window it hadn't seen counts from its first report; a full one has nothing left to mark.
    expect(g.windows([const PlanWindow(name: 'seven_day', used: 0.2)], label), isEmpty);
    expect(GuardMarks(windowsAtStart: {w: 1}).windows([const PlanWindow(name: w, used: 1)], label), isEmpty);
  });
}
