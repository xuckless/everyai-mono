import 'dart:io';

import 'package:every_ai/features/artifacts/script/svg_script.dart';
import 'package:flutter_test/flutter_test.dart';

// Runs real programs in Deno (frontend/.deno or DENO_BIN); skipped where there is none.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final skip = svgScriptAvailable ? false : 'no Deno here';

  test("a program can't load files from outside its folder (imports, import() or eval)", () async {
    final dir = Directory.systemTemp.createTempSync('svg-secret');
    addTearDown(() => dir.deleteSync(recursive: true));
    final secret = File('${dir.path}/s.json')..writeAsStringSync('{"k":"SECRET-123"}');
    final path = secret.resolveSymbolicLinksSync();
    for (final code in [
      'import s from "$path" with {type: "json"}; console.log(JSON.stringify(s));',
      'const m = await import("$path", {with: {type: "json"}}); console.log(JSON.stringify(m.default));',
      'const m = await (0, eval)(`import(\${JSON.stringify("$path")}, {with: {type: "json"}})`); console.log(JSON.stringify(m.default));',
      'const m = await import("file://" + "$path", {with: {type: "json"}}); console.log(JSON.stringify(m.default));',
    ]) {
      final run = await runSvgScript(code);
      expect('${run.output} ${run.error}', isNot(contains('SECRET-123')), reason: code);
      expect(run.error, isNotNull, reason: code);
    }
  }, skip: skip);
}
