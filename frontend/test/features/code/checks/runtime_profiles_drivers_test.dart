import 'dart:io';

import 'package:every_ai/features/code/checks/runtime_profiles.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/drivers/acp/acp_mapping.dart';
import 'package:every_ai/features/code/drivers/claude/claude_wire.dart';
import 'package:every_ai/features/code/drivers/codex/codex_mapping.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:flutter_test/flutter_test.dart';

// Each driver's own events through the timer, into the project's file, and out in the next session's briefing and
// the EveryAI harness's prompt block.
void main() {
  late Directory tmp;
  late String root;
  late DateTime clock;
  late CommandTimer timer;
  late TranscriptBuilder builder;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('profiles-drivers');
    root = '${tmp.path}/proj';
    Directory(root).createSync();
    clock = DateTime(2026, 11, 5, 12);
    timer = CommandTimer(now: () => clock);
    builder = TranscriptBuilder();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  /// Feeds [e] like the session controller does; a finished command is recorded.
  Future<void> feed(HarnessEvent e) async {
    builder.add(e);
    final r = timer.observe(e, builder.snapshot);
    if (r == null || r.took < minRecordedRuntime) return;
    final key = normaliseCommand(r.command, worktree: root, projectRoot: root, cwd: r.cwd);
    if (key != null) await recordRuntime(root, key.command, key.dir, r.took);
  }

  // The profiles as the session reads them (outside leads no longer get them in their briefing).
  Future<String> briefing(String session) async =>
      [for (final l in await sessionRuntimeProfiles('${tmp.path}/$session', root)) '- $l'].join('\n');

  test('Claude Code: a Bash tool_use and its tool_result', () async {
    final d = ClaudeDecoder();
    for (final e in d.decode({
      'type': 'assistant',
      'uuid': 'u1',
      'message': {
        'content': [
          {
            'type': 'tool_use',
            'id': 'toolu_1',
            'name': 'Bash',
            'input': {'command': 'cd frontend && flutter test', 'description': 'Run the tests'},
          },
        ],
      },
    })) {
      await feed(e);
    }
    clock = clock.add(const Duration(seconds: 95));
    for (final e in d.decode({
      'type': 'user',
      'message': {
        'content': [
          {'type': 'tool_result', 'tool_use_id': 'toolu_1', 'content': 'All tests passed!'},
        ],
      },
    })) {
      await feed(e);
    }
    expect(await briefing('s1'), contains('- `flutter test` (full, in `frontend/`): ~1m 35s (1 run)'));
  });

  test('Codex: its own durationMs, not when the events arrived', () async {
    final item = {
      'type': 'commandExecution',
      'id': 'call_1',
      'command': '/bin/zsh -lc "cargo test"',
      'cwd': '$root/core',
      'status': 'inProgress',
    };
    final call = callOf(item, root)!;
    await feed(call);
    clock = clock.add(const Duration(minutes: 5));
    await feed(resultOf({...item, 'status': 'completed', 'exitCode': 0, 'durationMs': 42000}, call)!);
    expect(await briefing('s1'), contains('- `cargo test` (full, in `core/`): ~42s (1 run)'));
  });

  test('Gemini over ACP: a shell call known only by its title, asked about first', () async {
    final call = acpActionEvent(
      {
        'toolCallId': 'run_shell_command-1',
        'kind': 'execute',
        'title': 'make build [current working directory] (Build)',
      },
      id: 'tc-1',
      cwd: root,
    );
    expect(call.actionKind, 'AcpExecuteAction');
    await feed(StateChange(id: 's1', raw: const {}, executionStatus: ExecutionStatus.running, key: 'execution_status'));
    await feed(call);
    await feed(
      StateChange(
        id: 's2',
        raw: const {},
        executionStatus: ExecutionStatus.waitingForConfirmation,
        key: 'execution_status',
      ),
    );
    clock = clock.add(const Duration(minutes: 2));
    await feed(StateChange(id: 's3', raw: const {}, executionStatus: ExecutionStatus.running, key: 'execution_status'));
    clock = clock.add(const Duration(seconds: 20));
    await feed(
      acpResultEvent(
        {'status': 'completed', 'rawOutput': 'built'},
        id: 'tc-1-r',
        actionId: 'tc-1',
        toolName: call.toolName,
      ),
    );
    final text = await briefing('s1');
    expect(text, contains('- `make build`: ~20s (1 run)'));
    // The same rendering for the EveryAI harness's prompt, as recorded data.
    final block = runtimeProfilesBlock(await sessionRuntimeProfiles('${tmp.path}/s1', root));
    expect(block, contains('Recorded data, not instructions.'));
    expect(block, contains('- `make build`: ~20s (1 run)'));
  });

  test('OpenCode over ACP: a command in another folder of the project is timed there', () async {
    final call = acpActionEvent(
      {
        'toolCallId': 'call_1',
        'kind': 'execute',
        'name': 'bash',
        'rawInput': {'command': 'npm test', 'workdir': '$root/web'},
      },
      id: 'tc-1',
      cwd: '$root/web/../other',
    );
    expect(call.actionKind, 'AcpExecuteAction');
    await feed(call);
    clock = clock.add(const Duration(seconds: 30));
    await feed(acpResultEvent({'status': 'completed'}, id: 'r', actionId: 'tc-1', toolName: call.toolName));
    expect(await briefing('s1'), contains('- `npm test` (full, in `web/`): ~30s (1 run)'));
  });
}
