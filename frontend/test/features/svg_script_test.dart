import 'dart:io';

import 'package:every_ai/features/artifacts/script/svg_script.dart';
import 'package:flutter_test/flutter_test.dart';

// Runs real programs in Deno (frontend/.deno or DENO_BIN); skipped where there is none.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final skip = svgScriptAvailable ? false : 'no Deno here';

  test('a program draws with d3 and Rough.js and prints its SVG', () async {
    final run = await runSvgScript('''
const arc = d3.arc().innerRadius(40).outerRadius(80);
const pie = d3.pie()([3, 2, 1]);
const paths = pie.map((p, i) => `<path transform="translate(100 100)" d="\${arc(p)}" fill="\${["#e07a2f","#6e56cf","#2fa866"][i]}"/>`);
const sketch = roughGenerator.toPaths(roughGenerator.rectangle(210, 30, 150, 140, { seed: 1 }))
  .map((p) => `<path d="\${p.d}" stroke="\${p.stroke}" stroke-width="\${p.strokeWidth}" fill="\${p.fill ?? "none"}"/>`);
console.log("debug line");
console.log(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 200">\${paths.join("")}\${sketch.join("")}</svg>`);
''');
    expect(run.error, isNull);
    expect(run.svg, startsWith('<svg'));
    expect(RegExp('<path').allMatches(run.svg!).length, greaterThan(3));
    expect(run.output, contains('debug line'));
  }, skip: skip);

  test('errors, no output, and no permissions are reported, not thrown', () async {
    final bad = await runSvgScript('const x: number = ; ');
    expect(bad.svg, isNull);
    expect(bad.error, isNotNull);
    expect(bad.error, isNot(contains('everyai-svg-')));
    final silent = await runSvgScript('const a = 1;');
    expect(silent.error, contains('printed no <svg>'));
    final sneaky = await runSvgScript('console.log(await Deno.readTextFile("/etc/hosts"));');
    expect(sneaky.svg, isNull);
    expect(sneaky.error, contains('NotCapable'));
  }, skip: skip);

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

  test('only the last <svg> printed counts', () async {
    final run = await runSvgScript('console.log("<svg id=\\"a\\"></svg>"); console.log("<svg id=\\"b\\"></svg>");');
    expect(run.svg, '<svg id="b"></svg>');
  }, skip: skip);
}
