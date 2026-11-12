import 'dart:io';

import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/permissions.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/everyai/apply_patch.dart';
import 'package:every_ai/features/code/harness/everyai/llm.dart';
import 'package:every_ai/features/code/harness/everyai/shell_io.dart';
import 'package:every_ai/features/code/harness/everyai/tools_io.dart';
import 'package:flutter_test/flutter_test.dart';

String patch(List<String> lines) => ['*** Begin Patch', ...lines, '*** End Patch'].join('\n');

void main() {
  group('parsePatch / applyHunks', () {
    test('updates with context and an @@ anchor, whitespace-tolerant', () {
      const before = 'def a():\n    return 1\n\ndef b():\n    return 1   \n';
      final op =
          parsePatch(patch(['*** Update File: m.py', '@@ def b():', '-    return 1', '+    return 2'])).single
              as UpdateFile;
      expect(applyHunks(before, op.hunks), 'def a():\n    return 1\n\ndef b():\n    return 2\n');

      final ctx =
          parsePatch(
                patch([
                  '*** Update File: m.py',
                  '@@',
                  ' def a():',
                  '-  return 1', // indentation off: still found
                  '+    return 3',
                ]),
              ).single
              as UpdateFile;
      expect(applyHunks(before, ctx.hunks), startsWith('def a():\n    return 3\n'));
    });
  });

  group('the apply_patch tool', () {
    late Directory tmp;
    late ToolRunner runner;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('patch');
      runner = ToolRunner(
        root: tmp.path,
        shell: SessionShell(root: tmp.path, sessionTag: 't', scratchDir: '${tmp.path}/.sh'),
        gateway: GatewayClient(baseUrl: 'http://127.0.0.1:9/v1', apiKey: ''),
        sessionTag: 't',
      );
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('nothing is written unless every change applies, and edits need a read', () async {
      File('${tmp.path}/a.txt').writeAsStringSync('one\n');
      final unread = await runner.run('apply_patch', {
        'patch': patch(['*** Update File: a.txt', '@@', '-one', '+1']),
      });
      expect(unread.text, contains('read'));
      await runner.run('read', {'file_path': 'a.txt'});
      final bad = await runner.run('apply_patch', {
        'patch': patch(['*** Add File: b.txt', '+b', '*** Update File: a.txt', '@@', '-nope', '+1']),
      });
      expect(bad.isError, isTrue);
      expect(File('${tmp.path}/b.txt').existsSync(), isFalse);
      expect(File('${tmp.path}/a.txt').readAsStringSync(), 'one\n');
    });
  });

  group('permissions and transcript', () {
    ActionCall call(String patchText) => HarnessEvent.decode({
      'kind': 'ActionEvent',
      'id': 'p1',
      'tool_name': 'apply_patch',
      'tool_call_id': 'c1',
      'action': actionFor('apply_patch', {'patch': patchText}, '/work'),
    }) as ActionCall;

    final twoFiles = call(patch(['*** Add File: a.txt', '+a', '*** Update File: lib/b.dart', '@@', '-x', '+y']));

    test('apply_patch is an edit: Plan refuses, Ask asks, Auto-edit allows', () {
      const policy = PermissionPolicy(workingDir: '/work');
      expect(policy.decide(twoFiles, AgentMode.plan).source, DecisionSource.plan);
      expect(policy.decide(twoFiles, AgentMode.ask).verdict, Verdict.ask);
      expect(policy.decide(twoFiles, AgentMode.autoEdit).verdict, Verdict.allow);
      final outside = call(patch(['*** Add File: /etc/x.conf', '+a']));
      expect(policy.decide(outside, AgentMode.ask).verdict, Verdict.ask);
      expect(policy.decide(outside, AgentMode.fullAuto).verdict, Verdict.allow, reason: 'Full auto never asks');
    });

    test('an Edit rule allows a patch only when it covers every file', () {
      const libOnly = PermissionPolicy(
        workingDir: '/work',
        rules: PermissionRules(allow: ['Edit(lib/**)']),
      );
      expect(libOnly.decide(twoFiles, AgentMode.ask).verdict, Verdict.ask);
      const denyA = PermissionPolicy(
        workingDir: '/work',
        rules: PermissionRules(deny: ['Edit(a.txt)']),
      );
      expect(denyA.decide(twoFiles, AgentMode.fullAuto).verdict, Verdict.deny);
    });
  });
}
