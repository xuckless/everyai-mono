// Live check of the Cursor CLI driver (spends on the user's Cursor plan). Not part of `flutter test`:
//
//   EVAL_DIR=/path/to/scratch/repo [CURSOR_MODEL=…] [MCP_ECHO=/path/mcp_echo.py] \
//   flutter test tool/live_drivers/cursor_live_test.dart
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/drivers/acp/acp_driver.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:flutter_test/flutter_test.dart';

final _env = Platform.environment;

void main() {
  test('Cursor: shell, edit, MCP', () async {
    final dir = _env['EVAL_DIR']!;
    final data = await Directory.systemTemp.createTemp('everyai-cursor');
    final driver = AcpDriver(id: 'cursor', label: 'Cursor CLI', command: 'cursor-agent', dataDir: () async => data.path);
    print('detect: ${await driver.detect()}');
    final s = await driver.start(
      SessionSpec(
        workingDir: dir,
        model: _env['CURSOR_MODEL'] ?? '',
        mode: AgentMode.autoEdit,
        llmBaseUrl: '',
        llmApiKey: '',
        sessionTag: 'cursor-live',
        mcpConfig: {
          if (_env['MCP_ECHO'] case final p?) 'echo': {'command': 'python3', 'args': [p], 'env': <String, String>{}},
        },
      ),
    );
    final done = Completer<void>();
    var runs = 0;
    final sub = s.events.listen((e) {
      if (e is! StreamDelta) print('EV ${e.runtimeType} ${_short(e)}');
      if (e is StateChange && e.executionStatus == ExecutionStatus.waitingForConfirmation) {
        unawaited(s.respond(accept: true));
      }
      if (e is StateChange && e.executionStatus == ExecutionStatus.running) runs++;
      if (e is StateChange && e.executionStatus == ExecutionStatus.finished && runs > 0 && !done.isCompleted) {
        done.complete();
      }
    });
    await s.send(
      _env['PROMPT'] ??
          "Run the shell command 'ls -la', then create notes.txt containing 'hi', then read README.md, then call the "
              'echo_word MCP tool and tell me the word. Be brief.',
    );
    if (_env['SWITCH'] case final m?) {
      await Future<void>.delayed(const Duration(seconds: 3));
      try {
        await s.switchLlm(SessionSpec(workingDir: dir, model: m, mode: AgentMode.autoEdit, llmBaseUrl: '', llmApiKey: '', sessionTag: 'cursor-live'));
        print('SWITCH ok');
      } on Object catch (e) {
        print('SWITCH failed: $e');
      }
    }
    await done.future.timeout(const Duration(minutes: 5));
    await sub.cancel();
    print('data: ${data.path}');
    await s.close();
  }, timeout: const Timeout(Duration(minutes: 6)));
}

String _short(HarnessEvent e) {
  final s = jsonEncode(e.raw);
  return s.length > 700 ? '${s.substring(0, 700)}…' : s;
}
