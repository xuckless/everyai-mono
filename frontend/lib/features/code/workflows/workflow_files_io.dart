// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../../../core/process/supervisor.dart';
import '../drivers/short_run.dart';

/// The project's `.everyai/workflows/*.js` files (links skipped, none over
/// 256 KB), by stem.
Future<List<({String stem, String path, String source})>> projectWorkflowFiles(String projectDir) async {
  final dir = Directory('$projectDir/.everyai/workflows');
  final out = <({String stem, String path, String source})>[];
  try {
    if (!dir.existsSync()) return out;
    await for (final f in dir.list(followLinks: false)) {
      if (f is! File || !f.path.endsWith('.js')) continue;
      try {
        if (await f.length() > 256 * 1024) continue;
        final stem = f.uri.pathSegments.last.replaceFirst(RegExp(r'\.js$'), '');
        out.add((stem: stem, path: f.path, source: await f.readAsString()));
      } on FileSystemException {
        continue;
      }
    }
  } on FileSystemException {
    return out;
  }
  return out;
}

/// [ref] names a commit in the repository at [dir] (Security review's base).
Future<bool> isGitCommit(String dir, String ref) async {
  // `--end-of-options` keeps a ref that starts with a dash from being read as an option.
  final r = await runShort(
    'git',
    ['rev-parse', '--verify', '--quiet', '--end-of-options', '$ref^{commit}'],
    timeout: const Duration(seconds: 30),
    cwd: dir,
    owner: const ProbeOwner('git'),
  );
  return switch (r) {
    Finished(:final code) => code == 0,
    // Hung (stopped, verified) or no git: not known to be a commit.
    TimedOut() || Cancelled() || StartFailed() || Refused() => () {
      debugPrint('EveryAI workflows: ${runProblem('git rev-parse', r)}');
      return false;
    }(),
  };
}
