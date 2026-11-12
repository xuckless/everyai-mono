import 'dart:io';

import 'package:every_ai/features/code/harness/everyai/lsp_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ['/usr/bin/clangd', '/opt/homebrew/opt/llvm/bin/clangd'].where((p) => File(p).existsSync()).firstOrNull;
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
