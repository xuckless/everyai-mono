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
}
