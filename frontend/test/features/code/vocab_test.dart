import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/compaction.dart' show userTextOf;
import 'package:every_ai/features/code/domain/plan_batches.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/drivers/claude/claude_wire.dart' show claudeAction;
import 'package:every_ai/features/code/drivers/driver_events.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:flutter_test/flutter_test.dart';

ActionCall _claude(String id, String tool, Map<String, Object?> input) {
  final a = claudeAction(tool, input);
  return actionEvent(id: id, toolName: tool, kind: a.kind, args: a.args);
}

List<TranscriptItem> _fold(Iterable<HarnessEvent> events) {
  final b = TranscriptBuilder();
  events.forEach(b.add);
  return b.snapshot.items;
}

void main() {
  group('tool names', () {
    test('outside calls keep the harness name and are marked native; ours are not', () {
      final bash = _claude('a', 'Bash', {'command': 'ls'});
      expect(bash.toolName, 'Bash');
      expect(bash.native, isTrue);
      expect(bash.nativeName, 'Bash');
      expect(actionEvent(id: 'b', toolName: 'acp:edit', kind: 'FileEditorAction').nativeName, 'edit');
      expect(_claude('c', 'Read', {'file_path': '/x'}).nativeName, 'Read');
      final ours = HarnessEvent.decode({
        'kind': 'ActionEvent',
        'id': 'd',
        'tool_name': 'terminal',
        'tool_call_id': 'd',
        'action': {'kind': 'TerminalAction', 'command': 'ls'},
      }) as ActionCall;
      expect(ours.native, isFalse);
      expect(ours.nativeName, '');
    });
  });

  group('plan text', () {
    test('present_plan steps with an id and a check end the plan in a json batches block', () {
      PlanProposal plan(List<Map<String, Object?>> steps) => PlanProposal(
        ActionCall(
          id: 'p',
          raw: const {},
          toolName: presentPlanTool,
          toolCallId: 'p',
          action: {'kind': 'PresentPlanAction', 'title': 'Form', 'steps': steps},
        ),
      );
      final batched = plan([
        {
          'title': 'Add the form',
          'id': 'form',
          'files': ['lib/form.dart'],
          'check': {
            'files': ['test/form_test.dart'],
          },
        },
        {
          'title': 'Wire it',
          'id': 'wire',
          'check': {'command': 'make wire'},
        },
        {
          'title': 'Whole',
          'id': 'whole',
          'files': ['lib/app.dart'],
          'check': {'full': true},
        },
        {'title': 'Polish copy'},
        {'title': 'Broken', 'id': 'Bad Id'},
      ]);
      expect(batched.markdown, contains('## Batches\n```json batches\n'));
      expect(
        [for (final b in batchesInMarkdown(batched.markdown)!) b.toJson()],
        [
          {
            'id': 'form',
            'intent': 'Add the form',
            'files': ['lib/form.dart'],
            'check': {
              'files': ['test/form_test.dart'],
            },
          },
          {
            'id': 'wire',
            'intent': 'Wire it',
            'files': <String>[],
            'check': {'command': 'make wire'},
          },
          {
            'id': 'whole',
            'intent': 'Whole',
            'files': ['lib/app.dart'],
            'check': {'full': true},
          },
        ],
      );
      final plain = plan([
        {
          'title': 'Add the form',
          'files': ['lib/form.dart'],
        },
      ]);
      expect(plain.markdown, isNot(contains('batches')));
      expect(plain.markdown, endsWith('1. Add the form\n   Files: lib/form.dart'));
    });
  });

  group('briefing row', () {
    test('a briefing block is a row, never a user message', () {
      final (block, rest) = splitSessionBlock('<everyai-session>\nbrief\n</everyai-session>\n\nfix it');
      expect(block, 'brief');
      expect(rest, 'fix it');
      expect(splitSessionBlock('plain'), (null, 'plain'));
      expect(userTextOf('<everyai-session>\nbrief\n</everyai-session>\n\nfix it'), 'fix it');
      final user = HarnessEvent.decode({
        'kind': 'MessageEvent',
        'id': 'u',
        'source': 'user',
        'llm_message': {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': '<everyai-session>\nbrief\n</everyai-session>\n\nfix it'},
          ],
        },
      });
      final items = _fold([user]);
      expect(items.whereType<NoticeItem>().single.detail, 'brief');
      expect(items.whereType<UserTurn>().single.text, 'fix it');
    });
  });
}
