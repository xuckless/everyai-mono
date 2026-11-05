// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import 'package:every_ai/features/code/environments/discovery.dart';

/// A recorded command runner: answers by `exe args…`, and records every
/// call (with its environment). Unknown commands answer null, as a CLI that
/// didn't answer would.
final class FakeRunner {
  FakeRunner(this.answers);

  final Map<String, CommandResult?> answers;
  final calls = <String>[];
  final environments = <Map<String, String>>[];

  Future<CommandResult?> call(
    String exe,
    List<String> args, {
    Duration timeout = Duration.zero,
    Map<String, String> environment = const {},
  }) async {
    final key = [exe, ...args].join(' ');
    calls.add(key);
    environments.add(environment);
    return answers[key];
  }
}

CommandResult ok(String text, {int code = 0}) => (code: code, stdout: utf8.encode(text));

/// [text] as wsl.exe writes it: UTF-16LE, with a BOM when [bom].
List<int> utf16le(String text, {bool bom = true}) => [
  if (bom) ...[0xFF, 0xFE],
  for (final c in text.codeUnits) ...[c & 0xFF, c >> 8],
];

EnvironmentIo fakeIo(
  FakeRunner runner, {
  Map<String, String> clis = const {},
  HostOs os = HostOs.macos,
  String home = '/Users/a',
  Set<String> files = const {},
}) => EnvironmentIo(run: runner.call, which: (c) async => clis[c], os: os, home: home, exists: files.contains);
