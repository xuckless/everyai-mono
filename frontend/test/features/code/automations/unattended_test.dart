import 'package:every_ai/features/code/automations/unattended.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("unattended runs say what checks them: EveryAI's floor, except Codex in Auto", () {
    expect(unattendedChecks(AgentMode.auto, 'claude-code'), contains('safety floor and your deny rules still apply'));
    expect(unattendedChecks(AgentMode.fullAuto, 'codex'), contains('safety floor and your deny rules still apply'));
    expect(unattendedChecks(AgentMode.auto, 'codex'), contains("Codex's own reviewer decides"));
    expect(unattendedChecks(AgentMode.auto, 'codex'), isNot(contains('still apply')));
  });
}
