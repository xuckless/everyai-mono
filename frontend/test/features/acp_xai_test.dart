import 'dart:convert';

import 'package:every_ai/features/code/drivers/acp/acp_xai.dart';
import 'package:flutter_test/flutter_test.dart';

// Payloads adapted from T3 Code's xaiAcpExtension.test.ts (MIT, @ 8b44f42b),
// not recorded from a real `grok agent stdio`: unverified.

void main() {
  test('prompt completion: the direct method and turn_completed; wakes marked, nameless turns ignored', () {
    expect(xaiPromptDone('session/prompt_complete', {'sessionId': 's', 'promptId': 'p1', 'stopReason': 'end_turn'}), (
      sessionId: 's',
      promptId: 'p1',
      stopReason: 'end_turn',
      agentResult: null,
      wake: false,
      usage: null,
    ));
    expect(xaiPromptDone('session/prompt_complete', {'sessionId': 's', 'stopReason': 'end_turn'})?.promptId, isNull);
    expect(
      xaiPromptDone('session_notification', {
        'sessionId': 's',
        'update': {'sessionUpdate': 'turn_completed', 'prompt_id': 'p2', 'stop_reason': 'rate_limit'},
      })?.stopReason,
      'rate_limit',
    );
    expect(
      xaiPromptDone('session/update', {
        'update': {'sessionUpdate': 'turn_completed'},
      }),
      isNull,
    );
    expect(xaiPromptDone('session/prompt_complete', {'promptId': 'task-completed-abc'})?.wake, isTrue);
    final wake = xaiPromptDone('session/update', {
      'update': {
        'sessionUpdate': 'turn_completed',
        'prompt_id': 'task-completed-t1',
        'usage': {'inputTokens': 10},
      },
    });
    expect(wake?.wake, isTrue);
    expect(wake?.usage, {'inputTokens': 10});
    expect(
      xaiPromptDone('session_notification', {
        'update': {'sessionUpdate': 'subagent_finished', 'prompt_id': 'p'},
      }),
      isNull,
    );
    expect(xaiPromptDone('task_completed', const {}), isNull);
  });

  test('kills: a finished kill ends the tasks it names; a failed one or another outcome ends nothing', () {
    Map<String, Object?> call(Map<String, Object?> data, {String status = 'completed', String title = 'kill'}) => {
      'title': title,
      'status': status,
      ...data,
    };
    expect(
      xaiKilled(
        call({
          'rawInput': {'task_id': 'call-bg-1'},
          'rawOutput': {'type': 'KillTask'},
        }),
      ),
      ['call-bg-1'],
    );
    expect(
      xaiKilled(
        call({
          'rawInput': {
            'variant': 'KillTask',
            'task_ids': ['a', 'b'],
            'taskId': 'a',
          },
        }),
      ),
      ['a', 'b'],
    );
    expect(
      xaiKilled(
        call({
          'rawInput': {'task_id': 't'},
          'rawOutput': {'type': 'KillTask', 'outcome': 'already_exited'},
        }),
      ),
      ['t'],
    );
    expect(
      xaiKilled(
        call({
          'rawInput': {'task_id': 't'},
        }, title: 'kill_command_or_subagent t'),
      ),
      ['t'],
    );
    expect(
      xaiKilled(
        call({
          'rawInput': {'variant': 'KillTask', 'task_id': 't'},
          'rawOutput': {
            'type': 'KillTask',
            'Result': {'outcome': 'error'},
          },
        }),
      ),
      isEmpty,
    );
    expect(
      xaiKilled(
        call({
          'rawInput': {'variant': 'KillTask', 'task_id': 't'},
        }, status: 'failed'),
      ),
      isEmpty,
    );
    expect(
      xaiKilled(
        call({
          'rawInput': {'task_id': 't'},
        }),
      ),
      isEmpty,
    );
  });

  test('redaction: env and header values, secret-named strings; names kept; input untouched', () {
    final input = <String, Object?>{
      'servers': [
        {
          'name': 'github',
          'command': 'npx',
          'env': {
            'GITHUB_TOKEN': 'ghp-secret',
            'NESTED': {'x': 'sk-deep'},
          },
          'headers': [
            {'name': 'Authorization', 'value': 'Bearer sk-secret'},
          ],
          'apiKey': 'sk-key',
          'token': 'tok-1',
          'tokens': 3,
        },
      ],
    };
    final before = jsonEncode(input);
    final out = jsonEncode(xaiRedacted(input));
    for (final secret in ['ghp-secret', 'sk-deep', 'sk-secret', 'sk-key', 'tok-1']) {
      expect(out, isNot(contains(secret)));
    }
    final server = ((xaiRedacted(input)! as Map)['servers'] as List).single as Map;
    expect(server['env'], {
      'GITHUB_TOKEN': '<redacted>',
      'NESTED': {'x': '<redacted>'},
    });
    expect(server['headers'], [
      {'name': 'Authorization', 'value': '<redacted>'},
    ]);
    expect((server['name'], server['command'], server['tokens']), ('github', 'npx', 3));
    expect(jsonEncode(input), before);
  });

  test('a no-terminal exit, on macOS and Linux', () {
    expect(isNoTtyExit('Error: Device not configured (os error 6)'), isTrue);
    expect(isNoTtyExit('Stopped: Error: Device not configured (os error 6)'), isTrue);
    expect(isNoTtyExit('Error: No such device or address (os error 6)'), isTrue);
    expect(isNoTtyExit('Error: No such file or directory (os error 2)'), isFalse);
    expect(isNoTtyExit('os error 60'), isFalse);
    expect(isNoTtyExit(''), isFalse);
  });
}
