import 'dart:io';

import 'package:every_ai/features/code/harness/everyai/lsp_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('languages by extension, and the language ids LSP wants', () {
    expect(lspLanguageOf('src/app.tsx'), LspLanguage.typescript);
    expect(lspLanguageOf('a/b.py'), LspLanguage.python);
    expect(lspLanguageOf('lib/main.dart'), LspLanguage.dart);
    expect(lspLanguageOf('main.c'), LspLanguage.cpp);
    expect(lspLanguageOf('README.md'), isNull);
    expect(lspLanguageOf('.github/workflows'), isNull);
    expect(lspLanguageId(LspLanguage.typescript, 'x.tsx'), 'typescriptreact');
    expect(lspLanguageId(LspLanguage.typescript, 'x.mjs'), 'javascript');
    expect(lspLanguageId(LspLanguage.cpp, 'x.c'), 'c');
  });

  test('the tool text: errors first, capped, information left out; the edit hint only when errors grew', () {
    LspDiagnostic d(int line, int severity, String m) =>
        (line: line, column: 2, severity: severity, message: m, source: 'ts');
    final text = formatDiagnostics({
      'a.ts': [d(3, 2, 'unused x'), d(1, 1, 'Cannot find name y'), d(9, 3, 'info')],
      'b.ts': [d(4, 1, 'Type mismatch\nmore detail')],
    });
    expect(text.split('\n'), [
      '2 errors, 1 warning in 2 files:',
      'a.ts:1:2: error: Cannot find name y [ts]',
      'b.ts:4:2: error: Type mismatch [ts]',
      'a.ts:3:2: warning: unused x [ts]',
    ]);
    expect(formatDiagnostics({'a.ts': []}), 'No errors or warnings in 1 file.');
    expect(
      formatDiagnostics({
        'a.ts': [for (var i = 0; i < 5; i++) d(i, 1, 'e$i')],
      }, max: 2),
      endsWith('… and 3 more.'),
    );
    expect(editDiagnosticsHint('a.ts', 1, 1), isNull);
    expect(editDiagnosticsHint('a.ts', 0, 2), 'This edit added 2 errors in a.ts; call diagnostics to see them.');
  });

  test('apply_patch targets: added, updated and moved-to paths', () {
    const patch =
        '*** Begin Patch\n*** Add File: a.ts\n+x\n*** Update File: b.py\n*** Move to: c.py\n@@\n-x\n+y\n'
        '*** Delete File: d.go\n*** End Patch';
    expect(patchTargets(patch), ['a.ts', 'b.py', 'c.py']);
  });

  final clangd = [
    '/usr/bin/clangd',
    '/opt/homebrew/opt/llvm/bin/clangd',
  ].where((p) => File(p).existsSync()).firstOrNull;
  test('a real server (clangd): an error is found, then gone once the file is fixed', () async {
    final tmp = await Directory.systemTemp.createTemp('lsp');
    addTearDown(() => tmp.delete(recursive: true));
    final file = File('${tmp.path}/main.c')..writeAsStringSync('int main(void) { return missing; }\n');
    final hub = LspHub(
      root: tmp.path,
      toolsDir: '${tmp.path}/tools',
      environment: () async => {...Platform.environment, 'PATH': File(clangd!).parent.path},
    );
    addTearDown(hub.close);
    final first = await hub.check(file.path);
    expect(first, isNotNull);
    expect(lspErrors(first!), 1);
    expect(first.single.message, contains('missing'));
    expect(await hub.knownErrors(file.path), 1);
    file.writeAsStringSync('int main(void) { return 0; }\n');
    expect(await hub.check(file.path), isEmpty);
    expect((await hub.all()).keys, [lspCanonical(file.path)]);
  }, skip: clangd == null ? 'clangd is not installed' : false);

  test("nothing from the project runs: no project-local servers, Dart plugins refused, Rust's build scripts off", () {
    expect(lspCandidates(LspLanguage.typescript), isEmpty, reason: 'TypeScript runs on the pinned install only');
    expect(lspProjectCodeRefusal(LspLanguage.dart, analysisOptions: 'analyzer:\n  errors: {}\n'), isNull);
    expect(
      lspProjectCodeRefusal(LspLanguage.dart, analysisOptions: 'plugins:\n  my_lints: ^1.0.0\n'),
      contains('plugins'),
    );
    expect(lspInitOptions(LspLanguage.rust), containsPair('procMacro', {'enable': false}));
  });

  // Live (downloads from npm): EVERYAI_LSP_NPM=1 flutter test test/features/lsp_test.dart
  test(
    'the pinned TypeScript server installs with npm ci and finds a type error',
    () async {
      final tmp = await Directory.systemTemp.createTemp('lsp-ts');
      addTearDown(() => tmp.delete(recursive: true));
      final file = File('${tmp.path}/a.ts')..writeAsStringSync('const n: number = "text";\n');
      final hub = LspHub(root: tmp.path, toolsDir: '${tmp.path}/tools');
      addTearDown(hub.close);
      final found = await hub.check(file.path, timeout: const Duration(seconds: 120));
      expect(hub.missing, isEmpty);
      expect(lspErrors(found!), 1);
      expect(found.single.message, contains('string'));
    },
    skip: Platform.environment['EVERYAI_LSP_NPM'] == '1' ? false : 'live: set EVERYAI_LSP_NPM=1',
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test('repo files that make a toolchain run project code keep rust-analyzer and the Dart server off', () {
    final tmp = Directory.systemTemp.createTempSync('lsp-refuse');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final root = tmp.path;
    expect(projectCodeRefusal(root, LspLanguage.rust), isNull);
    Directory('$root/crates/a/.cargo').createSync(recursive: true);
    File('$root/crates/a/.cargo/config.toml').writeAsStringSync('[build]\nrustc = "./x"\n');
    expect(projectCodeRefusal(root, LspLanguage.rust), contains('crates/a/.cargo/config.toml'));

    File('$root/analysis_options.yaml').writeAsStringSync('include: shared.yaml\n');
    File('$root/shared.yaml').writeAsStringSync('analyzer:\n  errors: {}\n');
    expect(projectCodeRefusal(root, LspLanguage.dart), isNull);
    // Plugins through an include, through a package, or in a nested package.
    File('$root/shared.yaml').writeAsStringSync('plugins:\n  x: any\n');
    expect(projectCodeRefusal(root, LspLanguage.dart), contains('plugins'));
    File('$root/shared.yaml').writeAsStringSync('');
    File('$root/analysis_options.yaml').writeAsStringSync('include: package:lints/recommended.yaml\n');
    expect(projectCodeRefusal(root, LspLanguage.dart), isNotNull, reason: "a package include it can't find");
    Directory('$root/.dart_tool').createSync();
    Directory('$root/pkgs/lints/lib').createSync(recursive: true);
    File('$root/pkgs/lints/lib/recommended.yaml').writeAsStringSync('linter:\n  rules: []\n');
    File('$root/.dart_tool/package_config.json').writeAsStringSync(
      '{"configVersion": 2, "packages": [{"name": "lints", "rootUri": "../pkgs/lints", "packageUri": "lib/"}]}',
    );
    expect(projectCodeRefusal(root, LspLanguage.dart), isNull);
    Directory('$root/packages/b').createSync(recursive: true);
    File('$root/packages/b/analysis_options.yaml').writeAsStringSync('analyzer:\n  plugins:\n    - x\n');
    expect(projectCodeRefusal(root, LspLanguage.dart), contains('packages/b/analysis_options.yaml'));
  });
}
