import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:flutter_test/flutter_test.dart';

HarnessEvent _files(List<Object?> files) => HarnessEvent.decode({
  'kind': 'ActionEvent',
  'id': 'f1',
  'tool_name': presentFilesTool,
  'tool_call_id': 'tc1',
  'action': {'kind': 'ClientToolAction', 'files': files},
});

void main() {
  group('present_files', () {
    test('becomes a files item and never waits for the user', () {
      final b = TranscriptBuilder()
        ..add(
          HarnessEvent.decode({
            'kind': 'ConversationStateUpdateEvent',
            'key': 'execution_status',
            'value': 'waiting_for_confirmation',
          }),
        )
        ..add(
          _files([
            {'path': 'out/report.pdf', 'title': 'Report', 'description': 'The summary'},
            {'path': 'build/app.zip'},
            'notes.md',
            {'path': ' '},
          ]),
        );
      final t = b.snapshot;
      final item = t.items.whereType<FilesDelivered>().single;
      expect(item.files.map((f) => f.path), ['out/report.pdf', 'build/app.zip', 'notes.md']);
      expect(item.files.map((f) => f.name), ['Report', 'app.zip', 'notes.md']);
      expect(t.held, isEmpty);
      expect(t.pending.single.toolName, presentFilesTool);
      // Every mode approves it on its own.
      for (final mode in AgentMode.values) {
        expect(mode.autoApproves(t.pending.single), isTrue, reason: mode.name);
      }
    });
  });

  group('notifications', () {});
}
