import 'package:every_ai/features/code/domain/plan_report.dart';
import 'package:flutter_test/flutter_test.dart';

const _claude = '''You are currently using your subscription to power your Claude Code usage

Current week (all models): 63% used · resets Nov 10 at 8pm (America/Toronto)
Current week (Fable): 0% used · resets Nov 10 at 8pm (America/Toronto)

What's contributing to your usage?
Approximate · sessions on this machine only · shares overlap

Last 24h · 3731 requests · 29 sessions
  83%  Give "general-purpose" subagents a cheaper model
  60%  Start fresh when you switch tasks · run /clear
  30%  Save workflows for big tasks · 55 agents ran, mostly in ~/cosc-projects/EveryAI
  20%  Stop sessions you no longer need · some ran 8 hours or more
  Top subagents: workflow-subagent 30%, general-purpose 13%, fork 2%
  Top MCP servers: claude-artifacts 1%, everyai 1%''';

void main() {
  test("Claude Code's /usage reads into limits, a heading, a period, shares and top lists", () {
    final parts = parsePlanReport(_claude);
    expect(parts.map((p) => p.runtimeType.toString()), [
      'PlanNote',
      'PlanLimit',
      'PlanLimit',
      'PlanHeading',
      'PlanPeriod',
      'PlanShare',
      'PlanShare',
      'PlanShare',
      'PlanShare',
      'PlanTop',
      'PlanTop',
    ]);
    final week = parts[1] as PlanLimit;
    expect(
      (week.label, week.scope, week.percent, week.resets),
      ('This week', 'all models', 63, 'resets Nov 10 at 8pm (America/Toronto)'),
    );
    final heading = parts[3] as PlanHeading;
    expect(heading.caption, 'Approximate · sessions on this machine only · shares overlap');
    final period = parts[4] as PlanPeriod;
    expect(period.label, 'Last 24h');
    expect(period.facts, ['3731 requests', '29 sessions']);
    final fresh = parts[6] as PlanShare;
    expect((fresh.percent, fresh.text, fresh.detail), (60, 'Start fresh when you switch tasks', 'run /clear'));
    final top = parts[9] as PlanTop;
    expect(top.label, 'Top subagents');
    expect(top.items.first, (name: 'workflow-subagent', share: '30%'));
  });

  test('text in another shape stays as plain notes', () {
    final parts = parsePlanReport('Signed in as someone\nPlan: Pro');
    expect(parts.whereType<PlanNote>().map((n) => n.text), ['Signed in as someone', 'Plan: Pro']);
    expect(parsePlanReport('  \n '), isEmpty);
  });
}
