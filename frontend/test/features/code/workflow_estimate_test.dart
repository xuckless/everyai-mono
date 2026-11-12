import 'package:every_ai/features/code/harness/events.dart' show PlanWindow;
import 'package:every_ai/features/code/workflows/workflow_estimate.dart';
import 'package:every_ai/features/code/workflows/workflow_library.dart' show loadBundledWorkflows;
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the bundled workflows say how many agents they start', () async {
    final rules = {for (final w in await loadBundledWorkflows()) w.id: w.agents};
    expect(rules['ultra']!.perItem, (4, 5));
    expect(rules['bugfix']!.fixed, (2, 3));
    expect(rules['security_review']!.fixed, (6, 6));
  });

  test('dollars on an EveryAI lead: past runs here first, else the model price; none on an outside lead', () {
    final byPrice = estimateWorkflow(
      workflowId: 'bugfix',
      rule: const AgentRule(fixed: (2, 3)),
      args: {},
      everyai: true,
      price: (3, 15),
      modelName: 'Sonnet 5.5',
    );
    final each = dollarsPerAgent(3, 15);
    expect(byPrice.dollars!.$1, closeTo(2 * each * 0.6, 1e-9));
    expect(byPrice.dollars!.$2, closeTo(3 * each * 1.4, 1e-9));
    expect(byPrice.ceilingMicros, (3 * each * 1.4 * 1e6).round());
    expect(byPrice.basis, "from Sonnet 5.5's price");
    expect(byPrice.time, isNull, reason: 'no time guess without past runs');

    const past = [
      PastRun(workflow: 'bugfix', agents: 2, spentMicros: 400000, took: Duration(minutes: 10)),
      PastRun(workflow: 'bugfix', agents: 3, spentMicros: 0, took: Duration(minutes: 9), everyai: false),
      PastRun(workflow: 'ultra', agents: 9, spentMicros: 9000000, took: Duration(minutes: 60)),
    ];
    final fromPast = estimateWorkflow(
      workflowId: 'bugfix',
      rule: const AgentRule(fixed: (2, 3)),
      args: {},
      everyai: true,
      past: past,
      price: (3, 15),
    );
    // $0.20 per agent from the one EveryAI-led run; time from both.
    expect(fromPast.dollars!.$2, closeTo(3 * 0.2 * 1.4, 1e-9));
    expect(fromPast.basis, 'from 1 past run here');
    expect(fromPast.time!.$1 < fromPast.time!.$2, isTrue);

    final outside = estimateWorkflow(
      workflowId: 'bugfix',
      rule: const AgentRule(fixed: (2, 3)),
      args: {},
      everyai: false,
      past: past,
      price: (3, 15),
      planWindows: const [PlanWindow(name: 'five_hour', used: 0.22, minutes: 300)],
    );
    expect(outside.dollars, isNull);
    expect(outside.planWindows.single.used, 0.22);
  });
}
