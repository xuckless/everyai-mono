import 'package:every_ai/features/code/domain/doom_loop.dart';
import 'package:every_ai/features/code/domain/spill.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:flutter_test/flutter_test.dart';

ActionCall call(String id, String command, {String tool = 'terminal', String kind = 'TerminalAction'}) =>
    ActionCall(id: id, raw: const {}, toolName: tool, toolCallId: 'tc-$id', action: {'kind': kind, 'command': command});

ToolResult result(String text, {String id = 'r1'}) => ToolResult(
  id: id,
  raw: const {},
  actionId: 'a1',
  toolCallId: 'tc-a1',
  toolName: 'terminal',
  observation: {
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
  outcome: ToolOutcome.ok,
);

void main() {
  group('DoomLoopDetector', () {
    test('fires on the third identical call in a row, once', () {
      final d = DoomLoopDetector();
      expect(d.add(call('1', 'flutter test')), isFalse);
      expect(d.add(call('2', 'flutter  test ')), isFalse);
      expect(d.add(call('3', 'flutter test')), isTrue);
      expect(d.looped?.id, '3');
      expect(d.add(call('4', 'flutter test')), isFalse);
    });

    test('a replayed call counts once, and the user speaking resets', () {
      final d = DoomLoopDetector();
      d.add(call('1', 'ls'));
      d.add(call('1', 'ls'));
      d.add(call('2', 'ls'));
      d.reset();
      expect(d.add(call('3', 'ls')), isFalse);
    });
  });

  group('local question card', () {});

  group('spill', () {
    test('over 2,000 lines is previewed', () {
      final text = List.generate(3000, (i) => 'l$i').join('\n');
      final s = spillOf(result(text))!;
      expect(s.lines, 3000);
      final p = spillPreview(s, '.everyai/spill/x.txt');
      expect(p, contains('l0\n'));
      expect(p, contains('l2999'));
      expect(p, isNot(contains('l1500\n')));
      expect(p, contains('.everyai/spill/x.txt'));
      expect(p.split('\n').length, lessThan(100));
    });
  });
}
