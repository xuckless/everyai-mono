import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/delivered_files.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/session_notifications.dart';
import 'package:every_ai/features/code/settings/agent_prompt.dart';
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
    test('is registered with the other client tools, held or not', () {
      for (final held in [true, false]) {
        final names = [for (final s in clientToolSpecs(held: held)) s['name']];
        expect(names, contains(presentFilesTool));
      }
      expect(clientTools, contains(presentFilesTool));
      expect(workingRules, contains('present_files'));
    });

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

    test('plan and question calls still wait', () {
      final b = TranscriptBuilder()
        ..add(
          HarnessEvent.decode({
            'kind': 'ConversationStateUpdateEvent',
            'key': 'execution_status',
            'value': 'waiting_for_confirmation',
          }),
        )
        ..add(
          HarnessEvent.decode({
            'kind': 'ActionEvent',
            'id': 'p',
            'tool_name': presentPlanTool,
            'action': {'title': 't', 'steps': <Object?>[]},
          }),
        );
      expect(b.snapshot.held, hasLength(1));
      expect(b.snapshot.pending, isEmpty);
    });

    test('paths resolve against the working directory', () {
      expect(resolveDelivered('/w/p', 'a/b.txt'), '/w/p/a/b.txt');
      expect(resolveDelivered('/w/p/', './a.txt'), '/w/p/a.txt');
      expect(resolveDelivered('/w/p', '/etc/x'), '/etc/x');
      expect(resolveDelivered('/w/p', 'file:///tmp/x.md'), '/tmp/x.md');
    });

    test('reveal uses the platform file manager', () {
      expect(revealCommand('/a/b.txt', os: 'macos').args, ['-R', '/a/b.txt']);
      expect(revealCommand('/a/b.txt', os: 'linux').args, ['/a']);
      expect(revealCommand('C:/a/b.txt', os: 'windows').args.single, r'/select,C:\a\b.txt');
    });
  });

  group('notifications', () {
    test('only needs-input, finished and failed-while-working notify', () {
      const s = SessionStatus.values;
      expect(notificationFor(SessionStatus.running, SessionStatus.needsInput, 'x')?.title, 'Needs your input');
      expect(notificationFor(SessionStatus.running, SessionStatus.done, 'x')?.title, 'Finished');
      expect(notificationFor(SessionStatus.running, SessionStatus.failed, 'x')?.title, 'Stopped on an error');
      expect(notificationFor(null, SessionStatus.needsInput, 'x'), isNull);
      expect(notificationFor(SessionStatus.needsInput, SessionStatus.needsInput, 'x'), isNull);
      expect(notificationFor(SessionStatus.idle, SessionStatus.done, 'x'), isNull);
      expect(notificationFor(SessionStatus.done, SessionStatus.running, 'x'), isNull);
      expect(s, isNotEmpty);
    });
  });
}
