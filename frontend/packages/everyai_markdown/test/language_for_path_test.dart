import 'package:everyai_markdown/everyai_markdown.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('maps file extensions to grammars', () {
    expect(languageForPath('lib/main.dart'), 'dart');
    expect(languageForPath('src/app.py'), 'python');
    expect(languageForPath('a/b/index.tsx'), 'typescript');
    expect(languageForPath('server.mjs'), 'javascript');
    expect(languageForPath('pubspec.yaml'), 'yaml');
    expect(languageForPath('config.yml'), 'yaml');
    expect(languageForPath('Cargo.toml'), 'ini');
    expect(languageForPath('page.html'), 'xml');
    expect(languageForPath('run.sh'), 'bash');
    expect(languageForPath('include/vec.hpp'), 'cpp');
    expect(languageForPath('lib/l10n/app_en.arb'), 'json');
    expect(languageForPath(r'C:\work\Program.cs'), 'csharp');
  });

  test('maps well-known file names', () {
    expect(languageForPath('Dockerfile'), 'dockerfile');
    expect(languageForPath('deploy/Dockerfile.prod'), 'dockerfile');
    expect(languageForPath('Makefile'), 'makefile');
    expect(languageForPath('ios/Podfile'), 'ruby');
    expect(languageForPath('.env.local'), 'ini');
  });

  test('unknown or missing extensions give no grammar', () {
    expect(languageForPath('notes.txt'), isNull);
    expect(languageForPath('LICENSE'), isNull);
    expect(languageForPath('weird.'), isNull);
    expect(languageForPath(''), isNull);
    expect(languageForPath('dir/'), isNull);
  });

  test('a mapped language highlights', () {
    final span = CodeHighlighter.highlight(
      'final x = 1;',
      languageForPath('a.dart'),
      base: const TextStyle(),
      theme: githubLightSyntaxTheme,
    );
    expect(span.toPlainText(), 'final x = 1;');
    expect(span.children, isNotNull);
  });
}
