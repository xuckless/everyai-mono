import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/transcript_export.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a session exports as Markdown with its header, calls and timings', () {
    final info = CodeSessionInfo(
      id: 's',
      projectId: 'p',
      title: 'Browser OS',
      conversationId: 'c',
      model: 'anthropic/claude-sonnet-5.5',
      mode: AgentMode.fullAuto,
      workingDir: '/work',
      createdAt: DateTime(2026, 10, 30),
      harness: 'everyai',
      effort: 'medium',
    );
    HarnessEvent ev(Map<String, Object?> raw) => HarnessEvent.decode(raw);
    final md = transcriptMarkdown(info, [
      ev({
        'kind': 'MessageEvent',
        'id': '1',
        'source': 'user',
        'timestamp': '2026-10-30T10:00:00',
        'llm_message': {'role': 'user', 'content': 'Build it'},
      }),
      ev({
        'kind': 'ActionEvent',
        'id': '2',
        'tool_name': 'bash',
        'timestamp': '2026-10-30T10:00:05',
        'action': {'kind': 'TerminalAction', 'command': 'ls'},
      }),
      ev({
        'kind': 'ObservationEvent',
        'id': '3',
        'action_id': '2',
        'tool_name': 'bash',
        'timestamp': '2026-10-30T10:01:10',
        'observation': {
          'content': [
            {'type': 'text', 'text': 'index.html'},
          ],
        },
      }),
    ]);
    expect(md, contains('# Browser OS'));
    expect(md, contains('- Harness: everyai'));
    expect(md, contains('- Tool calls: 1 (bash 1)'));
    expect(md, contains('```sh\nls\n```'));
    expect(md, contains('index.html'));
    expect(md, contains('Span of the events: 1m 10s'));
  });
}
