import 'package:every_ai/features/code/settings/agent_prompt.dart';
import 'package:every_ai/features/code/settings/code_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('each work style has its own rules, and forks are mentioned only where they apply', () {
    expect(workStyleBlock(WorkStyle.efficient), contains('smallest sound change'));
    expect(workStyleBlock(WorkStyle.balanced), contains('one polish pass'));
    expect(workStyleBlock(WorkStyle.thorough), contains('showcase'));
    expect(workStyleBlock(WorkStyle.balanced), isNot(contains('fork')));
    expect(workStyleBlock(WorkStyle.balanced, forks: true), contains('fork yourself'));
    expect(workStyleBlock(WorkStyle.efficient, forks: true), isNot(contains('fork')));
  });

  test('work style and fork isolation are stored, with the defaults left out', () {
    const plain = StoredCodeSettings();
    expect(plain.workStyle, WorkStyle.balanced);
    expect(plain.forksIsolated, isTrue);
    expect(plain.toJson()['global'], isEmpty);
    final set = plain.withWorkStyle(WorkStyle.thorough).withForksIsolated(false);
    final back = StoredCodeSettings.fromJson(set.toJson());
    expect(back.workStyle, WorkStyle.thorough);
    expect(back.forksIsolated, isFalse);
  });
}
