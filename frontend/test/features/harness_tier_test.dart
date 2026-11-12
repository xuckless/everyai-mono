import 'package:every_ai/features/code/settings/agent_prompt.dart';
import 'package:every_ai/features/code/settings/settings.dart' show AgentSettings;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('each level has its own rules, and forks are mentioned only where they apply', () {
    expect(tierBlock(HarnessTier.ultraEfficient), contains('smallest sound change'));
    expect(tierBlock(HarnessTier.efficient), contains('one polish pass'));
    expect(tierBlock(HarnessTier.thorough), contains('showcase'));
    expect(tierBlock(HarnessTier.thorough), contains('Check per part, not per edit'));
    expect(tierBlock(HarnessTier.efficient), isNot(contains('fork')));
    expect(tierBlock(HarnessTier.efficient, forks: true), contains('fork yourself'));
    expect(tierBlock(HarnessTier.ultraEfficient, forks: true), isNot(contains('fork')));
    // No phases or Bug fix rules are left in the prompt.
    final suffix = agentPromptSuffix(AgentSettings.defaults, tier: HarnessTier.thorough);
    expect(suffix, isNot(contains('HARNESS_MODE')));
    expect(suffix, isNot(contains('research → questions')));
  });

  test('moving a running session to another level sends the new rules', () {
    expect(
      tierChangeNote(HarnessTier.thorough),
      allOf(contains('Thorough tier'), contains('showcase'), contains('Check per part, not per edit')),
    );
  });
}
