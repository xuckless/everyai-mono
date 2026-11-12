import 'package:every_ai/features/code/handoff/native_import.dart';
import 'package:flutter_test/flutter_test.dart';

import 'native_source.dart';

void main() {
  test('without a session tag no importer writes anything', () async {
    for (final id in ['claude-code', 'codex', 'opencode']) {
      expect(
        await nativeImporterFor(id)!.write(source(sessionTag: '', model: 'a/b')),
        isNull,
        reason: id,
      );
    }
  });
}
