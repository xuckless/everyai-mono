import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("a library agent as the main agent adds its instructions to the session's rules", () {
    final block = mainAgentBlock('reviewer', '  Review carefully.\n');
    expect(block, startsWith('<MAIN_AGENT name="reviewer">'));
    expect(block, contains('Review carefully.'));
    expect(block, endsWith('</MAIN_AGENT>'));
  });

  test('the main agent round-trips with the session', () {
    final info = CodeSessionInfo(
      id: 's',
      projectId: 'p',
      title: 't',
      conversationId: 'c',
      model: 'm',
      mode: AgentMode.ask,
      workingDir: '/w',
      createdAt: DateTime(2026),
      mainAgent: 'reviewer',
    );
    expect(CodeSessionInfo.fromJson(info.toJson()).mainAgent, 'reviewer');
    expect(CodeSessionInfo.fromJson(info.copyWith(title: 'u').toJson()).mainAgent, 'reviewer');
  });
}
