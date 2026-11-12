import 'dart:io';

import 'package:every_ai/features/code/drivers/claude/claude_files.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('claude_cfg'));
  tearDown(() => root.deleteSync(recursive: true));

  test('a store without the session says it is gone', () async {
    Directory('${root.path}/projects/-tmp-x').createSync(recursive: true);
    expect(await claudeSessionExists('/tmp/x', 'abc', configDir: root.path), isFalse);
  });

  test('no projects folder means it cannot tell, so the resume is tried', () async {
    expect(await claudeSessionExists('/tmp/x', 'abc', configDir: root.path), isTrue);
  });
}
