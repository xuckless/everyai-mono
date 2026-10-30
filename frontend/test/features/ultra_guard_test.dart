import 'package:every_ai/features/code/ultra/domain/ultra_journal.dart';
import 'package:every_ai/features/code/ultra/domain/ultra_plan.dart';
import 'package:every_ai/features/code/ultra/ultra_providers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const limits = UltraLimits(budgetMicros: 10000000, wallTime: Duration(hours: 1));
  final plan = parseUltraPlan({
    'goal': 'g',
    'phases': [
      {
        'id': 'a',
        'steps': [
          {'id': 's', 'prompt': 'x'},
        ],
      },
    ],
  }).plan!;

  String? over({
    required UltraStage stage,
    UltraJournal? journal,
    int? orchestrator,
    Duration planning = Duration.zero,
    Duration synthesis = Duration.zero,
  }) => ultraGuardOver(
    stage: stage,
    limits: limits,
    journal: journal,
    orchestratorMicros: orchestrator,
    planningFor: planning,
    synthesizingFor: synthesis,
  );

  test('planning stops at the budget or the wall time', () {
    expect(over(stage: UltraStage.planning, orchestrator: 9999999), isNull);
    expect(over(stage: UltraStage.planning, orchestrator: 10000000), contains('cap'));
    expect(over(stage: UltraStage.planning, orchestrator: null, planning: const Duration(hours: 1)), contains('60'));
  });

  test('synthesis gets some room past the caps, then stops', () {
    UltraJournal journal({int steps = 0, Duration elapsed = Duration.zero}) => UltraJournal(
      runId: 'r',
      sessionId: 's',
      plan: plan,
      limits: limits,
      createdAt: DateTime(2026),
      budgetMicros: 10000000,
      elapsed: elapsed,
      orchestratorMicros: 500000,
    )..steps['a.s'] = StepRecord(key: 'a.s', phaseId: 'a', stepId: 's', title: 's', costMicros: steps);
    // At the cap after the steps: the write-up may still run.
    expect(over(stage: UltraStage.synthesizing, journal: journal(steps: 9500000), orchestrator: 600000), isNull);
    expect(over(stage: UltraStage.synthesizing, journal: journal(steps: 9500000), orchestrator: 1600000), isNotNull);
    expect(
      over(
        stage: UltraStage.synthesizing,
        journal: journal(elapsed: const Duration(minutes: 55)),
        synthesis: const Duration(minutes: 15),
      ),
      contains('minute'),
    );
    expect(over(stage: UltraStage.running, orchestrator: 99999999), isNull);
  });
}
