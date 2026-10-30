// Runs one live scenario against a real agent-server and the backend gateway.
// Not part of `flutter test`: run it explicitly with the environment set.
//
//   AGENT_SERVER_URL=http://127.0.0.1:18731 AGENT_SERVER_KEY=… GATEWAY_KEY=sk-eai-… \
//   EVAL_DIR=/path/to/repo EVAL_MODE=plan EVAL_MODEL=anthropic/claude-haiku-5.5 \
//   EVAL_PROMPT='…' flutter test tool/agent_eval/scenario_test.dart
import 'dart:io';

import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/harness/openhands_harness.dart';
import 'package:every_ai/features/code/settings/settings.dart';
import 'package:flutter_test/flutter_test.dart';

import 'driver.dart';

void main() {
  final env = Platform.environment;
  test('scenario', () async {
    final mode = AgentMode.values.byName(env['EVAL_MODE'] ?? 'plan');
    final prompt = await agentPromptFor(env['EVAL_DIR']!);
    final run = EvalRun(
      OpenHandsHarness(baseUrl: Uri.parse('${env['AGENT_SERVER_URL']}/'), sessionApiKey: env['AGENT_SERVER_KEY']!),
      SessionSpec(
        workingDir: env['EVAL_DIR']!,
        model: env['EVAL_MODEL'] ?? 'anthropic/claude-haiku-5.5',
        mode: mode,
        llmBaseUrl: '${env['API_BASE_URL'] ?? 'http://localhost:8080'}/v1',
        llmApiKey: env['GATEWAY_KEY']!,
        sessionTag: 'eval-${DateTime.now().millisecondsSinceEpoch}',
        initialMessage: modeNote(mode, env['EVAL_PROMPT']!),
        maxInputTokens: 200000,
        persona: prompt.persona,
        promptSuffix: prompt.suffix,
      ),
    );
    try {
      await run.run(timeout: Duration(minutes: int.tryParse(env['EVAL_MINUTES'] ?? '') ?? 10));
    } finally {
      // ignore: avoid_print
      print('conversation ${run.session.id}\n${run.report()}');
    }
  }, timeout: Timeout.none);
}
