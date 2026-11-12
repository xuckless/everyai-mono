import 'package:every_ai/features/code/drivers/acp/acp_agents.dart';
import 'package:every_ai/features/code/drivers/acp/acp_cursor.dart';
import 'package:every_ai/features/code/drivers/acp/acp_mapping.dart';
import 'package:every_ai/features/code/drivers/driver_policy.dart';
import 'package:every_ai/features/code/drivers/json_rpc.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:flutter_test/flutter_test.dart';

ActionCall _call(Map<String, Object?> call, {Set<String> servers = const {}, List<Object?> options = const []}) =>
    acpActionEvent({'toolCallId': 'c1', ...call}, id: 'tc-c1', mcpServers: servers, options: options);

void main() {
  group('tool calls', () {
    test('a command with its text is a TerminalAction the rules can judge', () {
      final c = _call({
        'kind': 'execute',
        'title': 'bash',
        'rawInput': {'command': 'ls -la', 'description': 'List'},
      });
      expect(
        (c.actionKind, c.str('command'), c.toolName, c.summary),
        ('TerminalAction', 'ls -la', 'acp:execute', 'bash'),
      );
      expect(autoDecidable(c), isTrue);
    });

    test('a command run in another folder keeps a kind of its own; one inside the project is judged', () {
      ActionCall run(String dir) => acpActionEvent(
        {
          'toolCallId': 'c1',
          'kind': 'execute',
          'name': 'bash',
          'rawInput': {'command': "echo 'x' >> .zshrc", 'workdir': dir},
        },
        id: 'tc-c1',
        cwd: '/w/repo',
      );
      for (final dir in ['/Users/me', '/w/repo/../other', '~', '/w/repo2']) {
        expect(run(dir).actionKind, 'AcpExecuteAction', reason: dir);
      }
      for (final dir in ['/w/repo', '/w/repo/sub/', 'sub']) {
        expect(run(dir).actionKind, 'TerminalAction', reason: dir);
      }
    });

    test('an edit with a diff names its file and shows only the changed lines', () {
      final old = [for (var i = 0; i < 50; i++) 'line $i'].join('\n');
      final c = _call({
        'kind': 'edit',
        'title': 'Edit a.dart',
        'content': [
          {'type': 'diff', 'path': '/w/a.dart', 'oldText': old, 'newText': old.replaceFirst('line 20', 'LINE 20')},
        ],
        'locations': [
          {'path': '/w/a.dart'},
        ],
      });
      expect((c.actionKind, c.str('command'), c.str('path')), ('FileEditorAction', 'str_replace', '/w/a.dart'));
      expect(c.str('old_str').split('\n'), [
        'line 17',
        'line 18',
        'line 19',
        'line 20',
        'line 21',
        'line 22',
        'line 23',
      ]);
      expect(c.str('new_str'), contains('LINE 20'));
      expect(autoDecidable(c), isTrue);
    });

    test('other kinds keep their own, which always ask', () {
      for (final (kind, ours) in [
        ('think', 'AcpThinkAction'),
        ('switch_mode', 'AcpSwitchModeAction'),
        ('other', 'AcpOtherAction'),
      ]) {
        final c = _call({'kind': kind, 'name': 'task'});
        expect(c.actionKind, ours);
        expect(c.toolName, 'acp:task');
        expect(autoDecidable(c), isFalse);
      }
    });
  });

  group('calls over time', () {
    test('updates merge into the call; a finished one gives its result', () {
      var call = mergeToolCall(const {}, {
        'sessionUpdate': 'tool_call',
        'toolCallId': 'c1',
        'status': 'pending',
        'kind': 'execute',
        'title': 'bash',
      });
      call = mergeToolCall(call, {
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'c1',
        'status': 'in_progress',
        'rawInput': {'command': 'make'},
        'title': null,
      });
      final a = acpActionEvent(call, id: 'tc-c1');
      expect((a.actionKind, a.str('command'), a.summary), ('TerminalAction', 'make', 'bash'));
      call = mergeToolCall(call, {
        'status': 'failed',
        'content': [
          {
            'type': 'content',
            'content': {'type': 'text', 'text': 'boom'},
          },
          {'type': 'terminal', 'terminalId': 't'},
        ],
      });
      final r = acpResultEvent(call, id: 'tr-c1', actionId: a.id, toolName: a.toolName);
      expect((r.outcome, r.text), (ToolOutcome.error, "boom\n(output shown in the agent's terminal)"));
      expect(acpResultText({'rawOutput': 'plain'}), 'plain');
      expect(
        acpResultText({
          'rawOutput': {'output': 'out'},
        }),
        'out',
      );
    });
  });

  group('usage limits', () {
    final now = DateTime.utc(2026, 11, 4, 12);
    DateTime? resets(JsonRpcError e) => acpUsageLimit(e, now: now)!.resetsAt;

    test("Gemini's quota messages are limits, with the reset it names", () {
      // Messages from gemini-cli 0.33.2's googleQuotaErrors (test l.599) and classifier.
      const capacity = JsonRpcError(
        500,
        'You have exhausted your capacity on this model. Your quota will reset after 19h14m47s.',
      );
      expect(resets(capacity), now.add(const Duration(hours: 19, minutes: 14, seconds: 47)));
      expect(resets(const JsonRpcError(500, 'You have exhausted your daily quota on this model.')), isNull);
      expect(
        acpUsageLimit(const JsonRpcError(500, 'Your quota will reset after 2h.'), now: now)!.resetsAt,
        now.add(const Duration(hours: 2)),
      );
    });
  });

  group('usage', () {
    test('usage_update moves the context ring and counts what was spent since the last one', () {
      final (first, total) = acpUsageUpdate({
        'used': 5000,
        'size': 200000,
        'cost': {'amount': 0.012, 'currency': 'USD'},
      }, id: 'a');
      expect((first.contextTokens, first.costMicros, total), (5000, 12000, 0.012));
      // The running total stays with the report, for a reopened session.
      expect(HarnessEvent.decode(first.raw).raw['acp_total'], 0.012);
      final (second, _) = acpUsageUpdate(
        {
          'used': 7000,
          'size': 200000,
          'cost': {'amount': 0.02, 'currency': 'USD'},
        },
        id: 'b',
        lastCost: total,
      );
      expect(second.costMicros, 8000);
      final (eur, kept) = acpUsageUpdate(
        {
          'used': 1,
          'size': 2,
          'cost': {'amount': 1, 'currency': 'EUR'},
        },
        id: 'c',
        lastCost: 0.02,
      );
      expect((eur.costMicros, kept), (null, 0.02));
    });
  });

  group('profiles', () {
    test('sign-in checks make no model call: a key in the environment, or Kiro whoami', () async {
      expect(kiroSignedInFrom(1, '{"account":null}'), isFalse);
      expect(kiroSignedInFrom(0, '{"accountType":"Social","email":"a@b.c"}'), isTrue);
      expect(kiroSignedInFrom(2, ''), isNull);
      for (final (cmd, key) in [('vibe-acp', 'MISTRAL_API_KEY'), ('droid', 'FACTORY_API_KEY')]) {
        final p = acpProfileOf(cmd);
        expect(await p.signedIn(cmd, env: {key: 'k'}), isTrue, reason: cmd);
        expect(await p.signedIn(cmd, env: {key: ' '}), isNull, reason: cmd);
        expect(await p.signedIn(cmd, env: const {}), isNull, reason: cmd);
      }
      // A Kiro key counts before whoami would run.
      expect(await acpProfileOf('kiro-cli').signedIn('kiro-cli', env: const {'KIRO_API_KEY': 'k'}), isTrue);
    });
  });
  group('Cursor', () {
    // Shapes seen live from cursor-agent 2026.11.05 (`agent acp`).
    test("a permission request's reason isn't the call's result; the output that comes later is", () {
      var call = mergeToolCall(const {}, {
        'toolCallId': 'c1\nfc_1',
        'kind': 'execute',
        'status': 'pending',
        'rawInput': {'command': 'git status | head -3'},
      });
      call = mergeToolCall(
        call,
        acpWithoutAskText({
          'toolCallId': 'c1\nfc_1',
          'content': [
            {
              'type': 'content',
              'content': {'type': 'text', 'text': 'Not in allowlist: git status, head'},
            },
          ],
        }),
      );
      call = mergeToolCall(call, {
        'status': 'completed',
        'rawOutput': {'exitCode': 0, 'stdout': 'On branch main\n', 'stderr': ''},
      });
      expect(acpResultText(call), 'On branch main\n');
    });

    test('to-dos: merge updates or adds by id, otherwise the list is replaced', () {
      var todos = cursorTodos({}, {
        'merge': false,
        'todos': [
          {'id': 'a', 'content': 'A', 'status': 'pending'},
          {'id': 'b', 'content': 'B', 'status': 'pending'},
        ],
      });
      todos = cursorTodos(todos, {
        'merge': true,
        'todos': [
          {'id': 'b', 'status': 'completed'},
          {'id': 'c', 'content': 'C', 'status': 'in_progress'},
        ],
      });
      expect(
        [for (final t in todos.values) (t['content'], t['status'])],
        [('A', 'pending'), ('B', 'completed'), ('C', 'in_progress')],
      );
      expect(cursorTodos(todos, {'todos': <Object?>[]}), isEmpty);
      final (call, result) = cursorTodoEvents(todos, id: 'x');
      expect((call.toolName, call.actionKind, result.actionId), ('acp:update_todos', 'TaskTrackerAction', 'x'));
    });
  });
}
