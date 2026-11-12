import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/floor_advice.dart';
import 'package:every_ai/features/code/domain/permissions.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:flutter_test/flutter_test.dart';

ActionCall _sh(String command, {String id = 'a'}) => HarnessEvent.decode({
  'kind': 'ActionEvent',
  'id': id,
  'tool_name': 'terminal',
  'action': {'kind': 'TerminalAction', 'command': command},
}) as ActionCall;

void main() {
  const policy = PermissionPolicy(workingDir: '/work/app');

  test('Full auto: a floor hit is refused with advice the model can act on', () {
    final v = outsideVerdict(policy, _sh('rm -rf ~'), AgentMode.fullAuto)!;
    expect(v.accept, isFalse);
    expect(v.reason, startsWith(floorAdviceLead));
    expect(v.reason, contains(floorReason('rm -rf ~')!));
    expect(v.reason, contains('ask them'));
  });

  test('once advised about a floor reason, Ask leaves it to the user and Full auto refuses, however it is worded', () {
    for (final mode in [AgentMode.ask, AgentMode.fullAuto]) {
      final advised = <String>{};
      final first = outsideVerdict(policy, _sh('rm -rf ~'), mode, advised: advised);
      if (mode == AgentMode.fullAuto) expect(first?.reason, startsWith(floorAdviceLead));
      advised.add(floorReason('rm -rf ~')!);
      for (final retry in ['rm -rf ~', 'rm  -rf   ~', 'cd /tmp && rm -rf ~']) {
        final v = outsideVerdict(policy, _sh(retry), mode, advised: advised);
        if (mode == AgentMode.fullAuto) {
          expect(v?.accept, isFalse, reason: retry);
        } else {
          expect(v, isNull, reason: retry);
        }
      }
    }
  });

  test('a floor hit is never approved on its own', () {
    for (final m in AgentMode.values.where((m) => m != AgentMode.bypass)) {
      for (final c in ['rm -rf ~', 'sudo rm -rf /usr', 'mkfs.ext4 /dev/sdb1', ':(){ :|:& };:']) {
        for (final advised in [
          <String>{},
          {floorReason(c) ?? ''},
        ]) {
          expect(outsideVerdict(policy, _sh(c), m, advised: advised)?.accept, isNot(isTrue), reason: '$m $c');
        }
      }
    }
  });

  test("the user's deny rules stay hard", () {
    const denying = PermissionPolicy(rules: PermissionRules(deny: ['rm *']));
    for (final m in [AgentMode.fullAuto, AgentMode.ask]) {
      final v = outsideVerdict(denying, _sh('rm -rf ~'), m)!;
      expect(v.accept, isFalse);
      expect(v.reason, isNot(startsWith(floorAdviceLead)));
      expect(v.reason, contains('`rm *` forbids it'));
    }
  });
}
