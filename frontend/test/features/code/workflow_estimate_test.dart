import 'package:every_ai/features/code/harness/events.dart' show PlanWindow;
import 'package:every_ai/features/code/workflows/workflow_estimate.dart';
import 'package:every_ai/features/code/workflows/workflow_library.dart' show loadBundledWorkflows;
import 'package:every_ai/features/code/workflows/workflow_meta.dart';
import 'package:every_ai/features/code/workflows/workflow_proposal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ultra = AgentRule(fixed: (1, 2), perItem: (4, 5));

  test('the bundled workflows say how many agents they start', () async {
    final rules = {for (final w in await loadBundledWorkflows()) w.id: w.agents};
    expect(rules['ultra']!.perItem, (4, 5));
    expect(rules['bugfix']!.fixed, (2, 3));
    expect(rules['security_review']!.fixed, (6, 6));
  });

  test('a meta rule reads ranges and single numbers, and nothing else', () {
    final meta = parseWorkflowMeta(
      "export const meta = { id: 'x', agents: { fixed: 2, perItem: [1, 3], items: 'parts' } }",
    );
    expect(meta!.agents!.fixed, (2, 2));
    expect(meta.agents!.perItem, (1, 3));
    expect(meta.agents!.itemsKey, 'parts');
    expect(AgentRule.of({'fixed': 'x'}), isNull);
    expect(
      AgentRule.of({
        'fixed': [3, 1],
      }),
      isNull,
    );
    expect(parseWorkflowMeta("export const meta = { id: 'x' }")!.agents, isNull);
  });

  test('agents per item when the args list them, per item when a first agent splits the task', () {
    final listed = estimateWorkflow(
      workflowId: 'ultra',
      rule: ultra,
      args: {
        'items': [<String, Object?>{}, <String, Object?>{}, <String, Object?>{}],
      },
      everyai: false,
    );
    expect(listed.agents, (13, 17));
    expect(listed.perItem, isNull);
    final split = estimateWorkflow(workflowId: 'ultra', rule: ultra, args: {'task': 'x'}, everyai: false);
    expect(split.perItem, (4, 5));
    expect(estimateLine(split), '~5–7 agents per item (4–5 each)');
    expect(estimateWorkflow(workflowId: 'p', rule: null, args: {}, everyai: true).agents, isNull);
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

  test('past runs keep the newest 30 and survive bad JSON', () {
    var stored = '';
    for (var i = 0; i < 35; i++) {
      stored = pastRunsWith(stored, PastRun(workflow: 'w$i', agents: 1, spentMicros: i, took: Duration.zero));
    }
    final runs = pastRunsOf(stored);
    expect(runs, hasLength(30));
    expect(runs.first.workflow, 'w5');
    expect(pastRunsOf('not json'), isEmpty);
  });

  test('a proposal reads back what it saved', () {
    const p = WorkflowProposal(
      id: 'p1',
      workflowId: 'ultra',
      title: 'Ultra',
      args: {
        'items': [
          {'id': 'a', 'title': 'Dark mode'},
          {'id': 'b'},
        ],
      },
      ctx: {'lead': {}},
      estimate: WorkflowEstimate(
        agents: (9, 12),
        dollars: (1.5, 3.0),
        time: (Duration(minutes: 20), Duration(minutes: 40)),
        planWindows: [PlanWindow(name: 'five_hour', used: 0.4, minutes: 300)],
        basis: 'b',
      ),
      phases: ['Split', 'Research'],
      capUsd: 25,
      items: ['Dark mode', 'b'],
    );
    final back = WorkflowProposal.fromJson(p.toJson())!;
    expect(back.estimate.toJson(), p.estimate.toJson());
    expect(back.items, p.items);
    expect(back.capUsd, 25);
    expect(proposalItems(p.args, 'items'), ['Dark mode', 'b']);
    expect(estimateLine(p.estimate), '~9–12 agents · \$1.50–3.00 · 20 min–40 min');
  });
}
