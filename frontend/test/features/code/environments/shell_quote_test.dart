// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';

import 'package:every_ai/features/code/environments/shell_quote.dart';
import 'package:flutter_test/flutter_test.dart';

const _tricky = ['a b', "it's", r'$HOME', '`x`', '"q"', r'back\slash', '', 'two\nlines', 'ünï ✓', '-n', '*', ';rm'];

void main() {
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
}
