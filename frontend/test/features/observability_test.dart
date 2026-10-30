import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/ui/transcript/transcript_items.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('elapsed time reads as seconds, then minutes', () {
    expect(formatElapsed(const Duration(seconds: 7)), '7s');
    expect(formatElapsed(const Duration(seconds: 65)), '1m 05s');
  });

  test('edits and commands count as changing files; reads do not', () {
    expect(editsFiles('file_editor'), isTrue);
    expect(editsFiles('terminal'), isTrue);
    expect(editsFiles('task_tracker'), isFalse);
  });
}
