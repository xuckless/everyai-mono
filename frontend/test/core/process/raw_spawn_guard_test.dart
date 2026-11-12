// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Processes are started and ended in `lib/core/process/` only (the supervisor: own sessions, the ledger, verified
/// kills; ptys through `pty_spawn_io.dart`'s `spawnPty`, which starts and adopts them in one place). A file that
/// needs a raw call for a reason the supervisor can't cover is listed here with its count and a one-line reason;
/// the list only shrinks: a new raw call fails, and so does a count that went down (lower it, or drop the file).
/// Empty since phase 2: nothing outside `lib/core/process/` starts or signals a process itself.
const _allowed = <String, int>{};

/// Calls and tear-offs (`run = Process.run`, `io.Process.start(`), across line breaks; `//` comments don't count.
final _raw = RegExp(r'\bProcess\s*\.\s*(?:start|run|runSync|killPid)\b|\bPty\s*\.\s*start\b');
final _comment = RegExp(r'(^|[ \t])//.*$', multiLine: true);

Map<String, int> rawSpawners() {
  final out = <String, int>{};
  for (final root in ['lib', 'packages']) {
    final d = Directory(root);
    if (!d.existsSync()) continue;
    for (final f in d.listSync(recursive: true).whereType<File>()) {
      final path = f.path.replaceAll(r'\', '/');
      if (!path.endsWith('.dart') || path.startsWith('lib/core/process/')) continue;
      final n = _raw.allMatches(f.readAsStringSync().replaceAll(_comment, '')).length;
      if (n > 0) out[path] = n;
    }
  }
  return out;
}

void main() {
  test('processes are started and ended only through lib/core/process (apart from the counts still listed)', () {
    final found = rawSpawners();
    final more = [
      for (final e in found.entries)
        if (e.value > (_allowed[e.key] ?? 0)) '${e.key}: ${e.value} (allowed ${_allowed[e.key] ?? 0})',
    ]..sort();
    final fewer = [
      for (final e in _allowed.entries)
        if ((found[e.key] ?? 0) < e.value) '${e.key}: ${found[e.key] ?? 0} (listed ${e.value})',
    ]..sort();
    expect(more, isEmpty, reason: 'Start and end processes through ProcessSupervisor (lib/core/process/).');
    expect(fewer, isEmpty, reason: 'Fewer raw calls than listed: lower the count, or take the file off the list.');
  });

  test('the pattern sees calls, tear-offs, prefixed and split calls', () {
    const code = '''
final a = await Process.run('x', []);
KillRunner run = Process.run;
final b = io.Process.start('y', []);
final c = await Process
    .start('z', []);
final d = Pty.start('sh');
// Process.run in a comment
''';
    expect(_raw.allMatches(code.replaceAll(_comment, '')).length, 5);
  });
}
