import 'package:every_ai/features/questions/domain/questions.dart';
import 'package:every_ai/features/code/domain/transcript.dart' show planApprovedReason, planRevisionLead;
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

    test("Gemini's shell call has only a title, so it keeps a kind of its own", () {
      final c = _call({'kind': 'execute', 'title': 'rm -rf build [current working directory] (Clean up)'});
      expect(c.actionKind, 'AcpExecuteAction');
      expect(c.summary, startsWith('rm -rf build'));
      expect(c.str('command'), isEmpty);
      expect(autoDecidable(c), isFalse);
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

    test("OpenCode's web search is a lookup the rules decide", () {
      final c = _call({
        'kind': 'other',
        'name': 'websearch',
        'title': 'websearch',
        'rawInput': {'query': 'acp spec'},
      });
      expect((c.actionKind, c.str('query')), ('WebSearchAction', 'acp spec'));
      expect(autoDecidable(c), isTrue);
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

    test('a new file is a create; a path from the input counts too', () {
      final created = _call({
        'kind': 'edit',
        'content': [
          {'type': 'diff', 'path': '/w/new.txt', 'oldText': null, 'newText': 'hi'},
        ],
      });
      expect((created.str('command'), created.str('file_text')), ('create', 'hi'));
      final fromInput = _call({
        'kind': 'edit',
        'rawInput': {'filePath': '/w/b.ts', 'oldString': 'a', 'newString': 'b'},
      });
      expect((fromInput.actionKind, fromInput.str('path')), ('FileEditorAction', '/w/b.ts'));
    });

    test('a patch over several files lists them all; one without paths asks', () {
      final c = _call({
        'kind': 'edit',
        'locations': [
          {'path': '/w/a'},
          {'path': '/w/b'},
        ],
      });
      expect(c.actionKind, 'ApplyPatchAction');
      expect(c.action['paths'], ['/w/a', '/w/b']);
      expect(autoDecidable(c), isTrue);
      expect(_call({'kind': 'edit', 'title': 'Something'}).actionKind, 'AcpEditAction');
    });

    test('deletes and moves are edits of their paths', () {
      final del = _call({
        'kind': 'delete',
        'locations': [
          {'path': '/w/a'},
        ],
      });
      expect((del.actionKind, del.str('patch_op'), del.str('path')), ('EditAction', 'delete', '/w/a'));
      final move = _call({
        'kind': 'move',
        'locations': [
          {'path': '/w/a'},
          {'path': '/w/b'},
        ],
      });
      expect(move.action['paths'], ['/w/a', '/w/b']);
    });

    test('reads, searches and fetches', () {
      final read = _call({
        'kind': 'read',
        'locations': [
          {'path': '/w/a.txt', 'line': 3},
        ],
      });
      expect((read.actionKind, read.str('path')), ('ReadFileAction', '/w/a.txt'));
      final search = _call({
        'kind': 'search',
        'rawInput': {'pattern': 'TODO', 'path': '/w'},
      });
      expect((search.actionKind, search.str('pattern'), search.str('path')), ('GrepAction', 'TODO', '/w'));
      final fetch = _call({
        'kind': 'fetch',
        'rawInput': {'url': 'https://example.com'},
      });
      expect((fetch.actionKind, fetch.str('url')), ('WebFetchAction', 'https://example.com'));
      expect(_call({'kind': 'read', 'title': 'many files'}).actionKind, 'AcpReadAction');
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

  group('MCP calls', () {
    test("OpenCode's everyai_<tool> name is our host tool, with its arguments", () {
      final c = _call(
        {
          'kind': 'other',
          'title': 'everyai_ask_user_question',
          'rawInput': {
            'questions': [
              {'question': 'Which?'},
            ],
          },
        },
        servers: {'everyai'},
      );
      expect(
        (c.actionKind, c.toolName, c.str('server'), c.str('tool')),
        ('MCPToolAction', 'everyai__ask_user_question', 'everyai', 'ask_user_question'),
      );
      expect(c.action['questions'], isA<List<Object?>>());
    });

    test("Gemini's options name the server and tool; the title holds the arguments", () {
      final c = _call(
        {'kind': 'other', 'title': '{"plan":"Do it"}'},
        options: [
          {'optionId': 'proceed_always_server', 'name': 'Always Allow everyai', 'kind': 'allow_always'},
          {'optionId': 'proceed_always_tool', 'name': 'Always Allow present_plan', 'kind': 'allow_always'},
          {'optionId': 'proceed_once', 'name': 'Allow', 'kind': 'allow_once'},
        ],
      );
      expect((c.toolName, c.str('plan')), ('everyai__present_plan', 'Do it'));
    });

    test("another server's tool keeps its server; an unknown prefix isn't MCP", () {
      final c = _call({'kind': 'other', 'name': 'github_search_issues'}, servers: {'github', 'everyai'});
      expect((c.actionKind, c.toolName, c.str('server')), ('MCPToolAction', 'github__search_issues', 'github'));
      expect(_call({'kind': 'other', 'name': 'jira_find'}, servers: {'github'}).actionKind, 'AcpOtherAction');
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

    test('a plan is a task list that never waits', () {
      final (call, result) = acpPlanEvents([
        {'content': 'Read', 'status': 'completed', 'priority': 'high'},
        {'content': 'Write', 'status': 'in_progress', 'priority': 'high'},
        {'content': 'Test', 'status': 'pending', 'priority': 'low'},
      ], id: 'p1');
      expect(call.actionKind, 'TaskTrackerAction');
      expect(
        [for (final t in call.action['task_list']! as List<Object?>) (t! as Map)['status']],
        ['done', 'in_progress', 'todo'],
      );
      expect((result.actionId, result.outcome), ('p1', ToolOutcome.ok));
      expect(autoDecidable(call), isTrue);
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

    test("Gemini's capacity text with a short reset is the retried throttle, not a limit", () {
      // Google sends the same text for RATE_LIMIT_EXCEEDED (googleQuotaErrors.test.js l.231, l.258).
      for (final e in const [
        JsonRpcError(500, 'You have exhausted your capacity on this model. Your quota will reset after 0s.'),
        JsonRpcError(500, 'You have exhausted your capacity on this model. Your quota will reset after 5m.'),
        JsonRpcError(500, 'You have exhausted your capacity on this model.'),
      ]) {
        expect(acpUsageLimit(e, now: now), isNull, reason: e.message);
      }
    });

    test("Gemini's rate limits and other errors are not limits", () {
      for (final e in const [
        JsonRpcError(429, 'Rate limit exceeded. Try again later.'),
        JsonRpcError(500, 'Resource exhausted.\nSuggested retry after 60s.'),
        JsonRpcError(-32603, 'Internal error'),
      ]) {
        expect(acpUsageLimit(e, now: now), isNull, reason: e.message);
      }
    });

    test("opencode acp's error name decides", () {
      JsonRpcError named(String name) =>
          JsonRpcError(-32603, 'Quota exceeded.', data: {'service': 'session', 'errorName': name});
      expect(resets(named('provider.quota')), isNull);
      expect(acpUsageLimit(named('provider.free-limit'), now: now), isNotNull);
      expect(acpUsageLimit(named('provider.rate-limit'), now: now), isNull);
      // The name wins over the words.
      expect(acpUsageLimit(named('provider.internal'), now: now), isNull);
    });
  });

  group('usage', () {
    test("OpenCode's input leaves the cache out; another agent's doesn't", () {
      final oc = acpTurnUsage({
        'inputTokens': 100,
        'outputTokens': 10,
        'thoughtTokens': 5,
        'cachedReadTokens': 800,
        'cachedWriteTokens': 50,
        'totalTokens': 965,
      }, id: 'u1')!;
      expect((oc.input, oc.output, oc.cached, oc.onPlan), (950, 15, 800, true));
      final other = acpTurnUsage({
        'inputTokens': 900,
        'outputTokens': 10,
        'cachedReadTokens': 800,
        'totalTokens': 910,
      }, id: 'u2')!;
      expect((other.input, other.output, other.cached), (900, 10, 800));
      expect(acpTurnUsage(null, id: 'u3'), isNull);
    });

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

  group('session offers', () {
    test('models from config options (efforts for the current one), else the older field', () {
      final fromConfig = acpModels({
        'configOptions': [
          {
            'id': 'model',
            'category': 'model',
            'currentValue': 'b',
            'options': [
              {'value': 'a', 'name': 'A'},
              {
                'group': 'g',
                'name': 'Group',
                'options': [
                  {'value': 'b', 'name': 'B'},
                ],
              },
            ],
          },
          {
            'id': 'effort',
            'category': 'thought_level',
            'currentValue': 'default',
            'options': [
              {'value': 'low', 'name': 'Low'},
              {'value': 'default', 'name': 'Default'},
            ],
          },
        ],
      });
      expect(
        [for (final m in fromConfig) (m.id, m.isDefault, m.efforts.join(','))],
        [('a', false, ''), ('b', true, 'low')],
      );
      final legacy = acpModels({
        'models': {
          'availableModels': [
            {'modelId': 'gemini-2.5-pro', 'name': 'Pro'},
          ],
          'currentModelId': 'gemini-2.5-pro',
        },
      });
      expect((legacy.single.label, legacy.single.isDefault), ('Pro', true));
    });

    test("pictures go as image blocks only when the agent reads them; the user's MCP servers map over", () {
      expect(acpPrompt('hi', images: ['data:image/png;base64,QUJD'], imagesOk: true).last, {
        'type': 'image',
        'mimeType': 'image/png',
        'data': 'QUJD',
      });
      expect(acpPrompt('hi', images: ['data:image/png;base64,QUJD']), hasLength(1));
      final servers = acpMcpServers({
        'fs': {
          'command': 'npx',
          'args': ['-y', 'server'],
          'env': {'KEY': 'v'},
        },
        'web': {'url': 'https://mcp.example/mcp', 'transport': 'http'},
      });
      expect(servers, [
        {
          'name': 'fs',
          'command': 'npx',
          'args': ['-y', 'server'],
          'env': [
            {'name': 'KEY', 'value': 'v'},
          ],
        },
      ]);
      expect(
        acpMcpServers({
          'web': {'url': 'https://mcp.example/mcp'},
        }, http: true).single['type'],
        'http',
      );
    });
  });

  group('profiles', () {
    test("Gemini pins only its ACP flag; the user's own approval flags stay", () {
      expect(acpCommand('gemini', ['--acp']).args, ['--acp']);
      expect(acpCommand('gemini', ['--yolo', '-m', 'x']).args, ['--acp', '--yolo', '-m', 'x']);
      expect(acpCommand('/opt/bin/gemini', ['--approval-mode=auto_edit']).args, ['--acp', '--approval-mode=auto_edit']);
      expect(addArgs(['--acp'], ['--acp', '--include-directories', '/s']), ['--acp', '--include-directories', '/s']);
    });

    test('a command with spaces is split into words; OpenCode gets its acp subcommand', () {
      final dsh = acpCommand('dsh --profile acp', const []);
      expect((dsh.executable, dsh.profile.agent), ('dsh', AcpAgent.generic));
      expect(dsh.args, ['--profile', 'acp']);
      final oc = acpCommand('opencode', const []);
      expect((oc.executable, oc.profile.agent), ('opencode', AcpAgent.openCode));
      expect(oc.args, ['acp']);
    });

    test("each listed agent runs with its ACP flags; the user's own approval flags stay", () {
      final cases = <(String, List<String>, List<String>)>[
        ('copilot', ['--yolo', '-m', 'x'], ['--acp', '--stdio', '--yolo', '-m', 'x']),
        ('droid', ['--auto', 'high'], ['exec', '--output-format', 'acp-daemon', '--auto', 'high']),
        // The pipe needs Kiro's v3 engine and its own auth: a given one is replaced, value and all.
        (
          'kiro-cli',
          ['--agent-engine=v2', '--trust-tools', 'fs_write'],
          ['acp', '--agent-engine=v3', '--auth-method=cli', '--trust-tools', 'fs_write'],
        ),
        (
          'kiro-cli',
          ['--agent-engine', 'v2', '--trust-all-tools'],
          ['acp', '--agent-engine=v3', '--auth-method=cli', '--trust-all-tools'],
        ),
        ('cline', ['--auto-approve', 'true'], ['--acp', '--auto-approve', 'true']),
        ('qwen', ['--yolo'], ['--acp', '--yolo']),
        ('grok', ['--always-approve'], ['--no-auto-update', 'agent', 'stdio', '--always-approve']),
        ('agy', [], ['acp']),
        ('/opt/homebrew/bin/goose', [], ['acp']),
        ('vibe-acp', [], []),
        ('kimi', ['-y'], ['acp', '-y']),
        ('auggie', [], ['--acp']),
      ];
      for (final (cmd, own, want) in cases) {
        expect(acpCommand(cmd, own).args, want, reason: '$cmd $own');
      }
      expect(acpCommand('qwen', const []).profile.agent, AcpAgent.qwen);
      expect(acpCommand('kiro-cli', const []).profile.agent, AcpAgent.kiro);
      expect(acpCommand('goose', const []).profile.askMode, 'approve');
      expect(
        (acpCommand('cline', const []).profile.askMode, acpCommand('cline', const []).profile.planMode),
        ('act', 'plan'),
      );
    });

    test('auto-update stays off; no environment sets an approval mode', () {
      expect(acpProfileOf('droid').env(null), {
        'DROID_DISABLE_AUTO_UPDATE': 'true',
        'FACTORY_DROID_AUTO_UPDATE_ENABLED': 'false',
      });
      expect(acpProfileOf('auggie').env(null), {'AUGMENT_DISABLE_AUTO_UPDATE': '1'});
      expect(acpProfileOf('goose').env(null), isEmpty);
      expect(acpProfileOf('copilot').env(null), isEmpty);
      expect(
        acpProfileOf('goose').env((
          args: const <String>[],
          env: const {'X': '1'},
          initRequests: const [],
          instructions: null,
          firstPrompt: null,
        )),
        {'X': '1'},
      );
      expect(acpProfileOf('gemini').env(null), isEmpty);
    });

    test('an agent older than its profile needs shows the version problem; an odd line never blocks', () {
      final agy = acpProfileOf('agy');
      expect(
        acpVersionProblem(agy, 'Antigravity CLI', 'agy 1.4.11'),
        'Antigravity CLI 1.4.11 is too old: update to 1.5.0 or later.',
      );
      expect(acpVersionProblem(agy, 'Antigravity CLI', '1.5.0'), isNull);
      expect(acpVersionProblem(agy, 'Antigravity CLI', 'agy version 1.10.2 (abc)'), isNull);
      expect(acpVersionProblem(agy, 'Antigravity CLI', 'weird'), isNull);
      expect(acpVersionProblem(agy, 'Antigravity CLI', null), isNull);
      expect(acpVersionProblem(acpProfileOf('kiro-cli'), 'Kiro CLI', 'kiro-cli 2.35.9'), contains('2.36.0'));
      expect(acpVersionProblem(acpProfileOf('kiro-cli'), 'Kiro CLI', 'kiro-cli 2.37.1'), isNull);
      expect(acpVersionProblem(acpProfileOf('goose'), 'goose', '0.0.1'), isNull);
    });

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

    test("OpenCode keeps the briefing's inline config as it is, with the project's own config off", () {
      const config = '{"mcp":{"servers":{}}}';
      final env = withoutOpenCodeProjectConfig({'OPENCODE_CONFIG_CONTENT': config, 'X': '1'});
      expect(env, {'OPENCODE_CONFIG_CONTENT': config, 'X': '1', 'OPENCODE_DISABLE_PROJECT_CONFIG': '1'});
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

    test('an MCP call is the server and tool it names in its input', () {
      final s = acpShape({
        'kind': 'other',
        'title': 'everyai: diff_stats',
        'rawInput': {
          'providerIdentifier': 'everyai',
          'toolName': 'diff_stats',
          'args': {'base': 'main'},
        },
      });
      expect((s.kind, s.toolName, s.args['base']), ('MCPToolAction', 'everyai__diff_stats', 'main'));
    });

    test('usage is guessed from the text that went by, and not when the agent reports its own', () {
      final e = AcpUsageEstimate()
        ..start([
          {'type': 'text', 'text': 'x' * 400},
        ])
        ..produced(80)
        ..toolCall({
          'rawInput': {'command': 'ls'},
          'rawOutput': {'stdout': 'y' * 200},
        });
      final first = e.report('u1')!;
      expect((first.estimated, first.onPlan, first.output), (true, true, (80 + 16) ~/ 4));
      expect(first.contextTokens, (400 + 200 + 80 + 16) ~/ 4);
      e
        ..start([
          {'type': 'text', 'text': 'z' * 40},
        ])
        ..reported = true;
      expect(e.report('u2'), isNull);
    });

    test("both of its names get its profile: `acp` pinned, the user's own flags kept", () {
      for (final exe in ['agent', 'cursor-agent', '/Users/me/.local/bin/agent']) {
        final p = acpProfileOf(exe);
        expect(p.agent, AcpAgent.cursor, reason: exe);
        expect((p.askMode, p.planMode, p.needsConsent, p.mcpInConfig), ('agent', 'plan', true, false));
      }
      expect(acpCommand('cursor-agent', ['--force', '--model', 'gpt-6']).args, ['acp', '--force', '--model', 'gpt-6']);
      expect(acpCommand('agent acp', const []).args, ['acp']);
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

    test('plan replies: approved, changes with the words, anything else cancelled', () {
      expect(cursorPlanReply((text: planApprovedReason, isError: false)), {
        'outcome': {'outcome': 'accepted'},
      });
      expect(cursorPlanReply((text: '$planRevisionLead Smaller.', isError: false)), {
        'outcome': {'outcome': 'rejected', 'reason': '$planRevisionLead Smaller.'},
      });
      expect(cursorPlanReply((text: planApprovedReason, isError: true)), cursorCancelled);
      expect(cursorPlanReply((text: 'Something else', isError: false)), cursorCancelled);
      expect(cursorPlanArgs(const {})['title'], 'Plan');
    });

    test("a question card's answer that isn't an answers message goes back as skipped with its text", () {
      const params = {
        'questions': [
          {
            'id': 'q',
            'prompt': 'Go?',
            'options': [
              {'id': 'y', 'label': 'Yes'},
            ],
          },
        ],
      };
      expect(cursorAnswerReply(params, (text: 'Whatever', isError: false)), cursorSkipped('Whatever'));
      // Attached files ride in a note the reply has no slot for, even when every answer is a pick.
      final picked = answersReason(
        [Question.listFrom(cursorQuestionArgs(params)).single],
        [
          const QuestionAnswer(selected: {0}),
        ],
      );
      expect(cursorAnswerReply(params, (text: picked, isError: false))['outcome'], containsPair('outcome', 'answered'));
      final noted = '$picked\n\n[Attached: .everyai/uploads/a.png]';
      expect(cursorAnswerReply(params, (text: noted, isError: false)), cursorSkipped(noted));
      expect(cursorQuestionProblem(params), isNull);
      expect(cursorQuestionProblem(const {}), isNotNull);
    });

    test('a subagent of a custom type, and its duration', () {
      final call = cursorTaskCall({
        'description': 'Review',
        'prompt': 'Look',
        'subagentType': {'custom': 'reviewer'},
        'model': 'fast',
      }, id: 't');
      expect((call.actionKind, call.str('agent'), call.str('model')), ('TaskAction', 'reviewer', 'fast'));
      expect(
        [cursorTaskDone(4200), cursorTaskDone(65000), cursorTaskDone(null)],
        ['Done in 4.2 s.', 'Done in 65 s.', 'Done.'],
      );
    });
  });
}
