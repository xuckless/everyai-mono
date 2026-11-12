import 'dart:io';

import 'package:every_ai/core/config/version.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the version constant matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(r'^version:\s*([^+\s]+)', multiLine: true).firstMatch(pubspec)!.group(1);
    expect(version, appVersion);
  });
}
