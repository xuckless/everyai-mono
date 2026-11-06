// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';

import 'package:every_ai/features/code/environments/bridges.dart';
import 'package:every_ai/features/code/environments/shell_quote.dart';
import 'package:flutter_test/flutter_test.dart';

const _tricky = ['a b', "it's", r'$HOME', '`x`', '"q"', r'back\slash', '', 'two\nlines', 'ünï ✓', '-n', '*', ';rm'];

void main() {
  test('posixQuote leaves plain words and quotes the rest', () {
    expect(posixQuote('claude'), 'claude');
    expect(posixQuote('/usr/bin/a-b_c.d@1+2'), '/usr/bin/a-b_c.d@1+2');
    expect(posixQuote('a b'), "'a b'");
    expect(posixQuote("it's"), r"'it'\''s'");
    expect(posixQuote(r'$HOME'), r"'$HOME'");
    expect(posixQuote(''), "''");
    expect(posixCommand(['echo', 'a b', "c'd"]), r"echo 'a b' 'c'\''d'");
  });

  test('safeName refuses options, whitespace and control characters', () {
    expect(safeName('Ubuntu-22.04'), isTrue);
    expect(safeName('me@box.lan'), isTrue);
    for (final bad in ['', '-oProxyCommand=x', 'a b', 'a\tb', 'a\nb', 'a\x00b']) {
      expect(safeName(bad), isFalse, reason: bad);
    }
    expect(safeEnvName('EVERYAI_SESSION'), isTrue);
    expect(safeEnvName('A=B'), isFalse);
    expect(safeEnvName('1A'), isFalse);
    expect(() => checkEnvNames({'A B': 'x'}), throwsArgumentError);
  });

  test('a real /bin/sh splits posixCommand back into the same argv', () {
    final r = Process.runSync('/bin/sh', ['-c', 'printf "%s\\0" ${posixCommand(_tricky)}']);
    expect(r.exitCode, 0);
    final out = (r.stdout as String).split('\x00')..removeLast();
    expect(out, _tricky);
  }, skip: Platform.isWindows);

  test('a real /bin/sh runs bridgeScript with argv, cwd and env intact', () {
    final dir = Directory.systemTemp.createTempSync('a b \'q\' ');
    addTearDown(() => dir.deleteSync(recursive: true));
    final script = bridgeScript(
      '/bin/sh',
      ['-c', r'printf "%s\0" "$K" "$(pwd -P)" "$@"', 'sh', ..._tricky],
      cwd: dir.path,
      env: {'K': r"v $x 'y' `z`"},
    );
    final r = Process.runSync('/bin/sh', ['-c', script]);
    expect(r.exitCode, 0, reason: r.stderr as String);
    final out = (r.stdout as String).split('\x00')..removeLast();
    expect(out.first, r"v $x 'y' `z`");
    expect(out[1], dir.resolveSymbolicLinksSync());
    expect(out.sublist(2), _tricky);
  }, skip: Platform.isWindows);
}
