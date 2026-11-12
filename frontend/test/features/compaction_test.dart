import 'package:every_ai/features/code/domain/compaction.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:flutter_test/flutter_test.dart';

var _ids = 0;

ChatMessage _user(String text) => ChatMessage(id: 'u${_ids++}', raw: const {}, fromUser: true, text: text);
ChatMessage _agent(String text) => ChatMessage(id: 'a${_ids++}', raw: const {}, fromUser: false, text: text);

(ActionCall, ToolResult) _run(String command, String output) {
  final id = 'c${_ids++}';
  return (
    ActionCall(
      id: id,
      raw: const {},
      toolName: 'terminal',
      toolCallId: 't$id',
      action: {'kind': 'TerminalAction', 'command': command},
    ),
    ToolResult(
      id: 'r$id',
      raw: const {},
      actionId: id,
      toolName: 'terminal',
      observation: {
        'content': [
          {'type': 'text', 'text': output},
        ],
      },
      outcome: ToolOutcome.ok,
    ),
  );
}

List<HarnessEvent> _turn(String ask, List<(String, String)> runs, String reply) => [
  _user(ask),
  for (final (cmd, out) in runs)
    ...switch (_run(cmd, out)) {
      (final call, final result) => [call, result],
    },
  _agent(reply),
];

void main() {
  group('planCompaction', () {
    test('keeps the newest whole turns and summarizes the rest', () {
      final events = [
        ..._turn('first ask', [('ls', 'a\nb')], 'did one'),
        const StateChange(id: 's', raw: {}, executionStatus: ExecutionStatus.idle, key: 'execution_status'),
        ..._turn('second ask', [('cat a', 'x' * 100)], 'did two'),
        ..._turn('third ask', [('dart test', 'ok')], 'did three'),
      ];
      final plan = planCompaction(events, budget: const CompactionBudget(tail: 200))!;
      expect((plan.tail.first as ChatMessage).text, 'third ask');
      expect((plan.head.first as ChatMessage).text, 'first ask');
      expect(plan.head.whereType<StateChange>(), isEmpty);
      expect(renderTail(plan), contains('[tool call terminal]\n{"command":"dart test"}'));
    });
  });

  group('pruning', () {
    test('clears old tool output and cuts the newer output short', () {
      final events = [
        ..._turn('a', [('old', 'OLD' * 400)], 'x'),
        ..._turn('b', [('new', 'NEW' * 400)], 'y'),
        ..._turn('c', [], 'z'),
      ];
      final plan = planCompaction(events, budget: const CompactionBudget(tail: 20))!;
      final text = prunedHead(plan, budget: const CompactionBudget(protectedOutput: 1000, outputCap: 1000));
      expect(text, contains('[result of terminal]\n$clearedOutput'));
      expect(text, contains('NEWNEW'));
      expect(text, isNot(contains('OLDOLD')));
      expect(text, contains('characters cut'));
      // Mode and context notes are not the user's words.
      expect(text, isNot(contains('everyai-mode')));
    });
  });

  group('summary', () {});

  group('clearOldToolOutput', () {
    List<Map<String, Object?>> history(int steps, {int size = 30000}) => [
      {'role': 'system', 'content': 'rules'},
      {'role': 'user', 'content': 'do it'},
      for (var i = 0; i < steps; i++) ...[
        {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'c$i',
              'type': 'function',
              'function': {'name': i.isEven ? 'read' : 'bash', 'arguments': '{}'},
            },
          ],
        },
        {'role': 'tool', 'tool_call_id': 'c$i', 'content': 'x' * size},
      ],
    ];

    test('clears the oldest output down to the target, never the newest three steps', () {
      final messages = history(10);
      // 7 old results of 30K characters: about 52K tokens, over 40K.
      expect(clearOldToolOutput(messages), 5);
      final tools = messages.where((m) => m['role'] == 'tool').map((m) => m['content']! as String).toList();
      expect(tools.take(5), everyElement(startsWith('[output cleared to save context')));
      expect(tools[0], contains('re-run read'));
      expect(tools[1], contains('re-run bash'));
      expect(tools.skip(5), everyElement(hasLength(30000)));
      // Under the trigger now: nothing changes again (the cached prefix holds).
      expect(clearOldToolOutput(messages), 0);
    });

    test('the current user turn is kept when the output before it is enough to clear', () {
      // The last turn: 6 steps of 20K characters (5K tokens each), longer than three steps but under the trigger.
      final turn = [
        for (final m in history(6, size: 20000).skip(2))
          {...m, if (m['tool_call_id'] case final String id) 'tool_call_id': 't$id'},
      ];
      for (final m in turn) {
        if (m['tool_calls'] case [final Map<String, Object?> c]) {
          m['tool_calls'] = [
            {...c, 'id': 't${c['id']}'},
          ];
        }
      }
      final messages = [
        ...history(7),
        {'role': 'user', 'content': 'now the tests'},
        ...turn,
      ];
      // Before: the first turn's 7 results. The last turn's older steps stay, though three steps would allow them.
      expect(oldToolOutputs(messages).map((o) => o.callId), ['c0', 'c1', 'c2', 'c3', 'c4', 'c5', 'c6']);
      // A turn whose own output is over the trigger can clear its older steps (but never the newest three).
      final long = [
        ...history(2, size: 10),
        {'role': 'user', 'content': 'go on'},
        ...history(10).skip(2),
      ];
      expect(oldToolOutputs(long).map((o) => o.callId), ['c0', 'c1', 'c0', 'c1', 'c2', 'c3', 'c4', 'c5', 'c6']);
    });
  });

  test('the continuation message carries the plan, todos, files and skills before the recent turns', () {
    final m = continuationMessage(
      summary: '## Objective\nx',
      recent: '[user]\nhi',
      plan: '# Plan',
      todos: '- [ ] one',
      files: '<file path="a">a</file>',
      skills: '<skill path="s">s</skill>',
    );
    final order = ['<summary>', '<approved-plan>', '<todos>', '<files>', '<skills>', '<recent-turns>'];
    final at = [for (final t in order) m.indexOf(t)];
    expect(at, everyElement(greaterThanOrEqualTo(0)));
    expect([...at]..sort(), at);
    expect(splitCompacted(m)?.summary, '## Objective\nx');
    expect(continuationMessage(summary: 's', recent: ''), isNot(contains('<todos>')));
  });
}
