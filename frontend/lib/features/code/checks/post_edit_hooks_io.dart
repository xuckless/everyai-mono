// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';

import 'package:crypto/crypto.dart';

import '../domain/spill.dart';
import '../git/git_service.dart';
import '../harness/everyai/shell_io.dart';
import '../spill/spill.dart';
import 'post_edit_hooks.dart';

/// Runs the after-edit checks on the files of [workingDir] that changed in
/// [target] since snapshot [tree] (null: since the session's base). Each
/// command passes [refusal] first and runs in a [SessionShell] tagged
/// [sessionTag]. Returns the report for the lead ('' when clean), the tools
/// that did not run ('' when all did), and the snapshot the next run
/// compares with: taken before the checks, or after them when auto-format
/// wrote, so its writes are not checked again (the old one when git failed).
Future<({String report, String skipped, String? tree})> runPostEditHooks({
  required String workingDir,
  required String sessionTag,
  required String shellDir,
  required SessionWorktree target,
  required String? tree,
  required String? Function(String command) refusal,
  required bool autoFormat,
}) async {
  final List<String> changed;
  final String top, now;
  try {
    // One snapshot, compared with the last: no second pass over the whole folder.
    now = await GitService.snapshotTree(target);
    top = (await Process.run('git', ['-C', target.path, 'rev-parse', '--show-toplevel'])).stdout.toString().trim();
  } on Object {
    return (report: '', skipped: '', tree: tree);
  }
  try {
    changed = await GitService.changedBetween(target, tree ?? target.baseCommit, now);
  } on Object {
    // The old snapshot is gone (git pruned it): start again from this one.
    return (report: '', skipped: '', tree: now);
  }
  // git names the top folder with its links resolved (/private/var on macOS), so compare it that way.
  final String root;
  try {
    root = Directory(workingDir).resolveSymbolicLinksSync();
  } on Object {
    return (report: '', skipped: '', tree: now);
  }
  bool exists(String p) => FileSystemEntity.typeSync('$root/$p') != FileSystemEntityType.notFound;
  final files = [
    for (final p in changed)
      // git names paths from the top of the repository; checks see them from the session folder.
      if ('$top/$p' case final abs when top.isNotEmpty && abs.startsWith('$root/'))
        if (abs.substring(root.length + 1) case final rel when !rel.startsWith('.everyai/') && exists(rel)) rel,
  ];
  if (files.isEmpty) return (report: '', skipped: '', tree: now);
  final found = detectHooks(
    files,
    exists: exists,
    read: (p) {
      try {
        return File('$root/$p').readAsStringSync();
      } on Object {
        return null;
      }
    },
    autoFormat: autoFormat,
  );
  final shell = SessionShell(root: root, sessionTag: sessionTag, scratchDir: shellDir);
  final result = await runHooks(
    found.runs,
    run: (command, cancel) async {
      final r = await shell.run(command, timeout: hookCap, cancel: cancel);
      return (exit: r.exitCode, out: r.output);
    },
    refusal: refusal,
    digest: (p) {
      try {
        return md5.convert(File('$root/$p').readAsBytesSync()).toString();
      } on Object {
        return null;
      }
    },
    autoFormat: autoFormat,
  );
  final stamp = DateTime.now().millisecondsSinceEpoch;
  final HookReport all = (
    problems: result.problems,
    formatted: result.formatted,
    skipped: [...found.skipped, ...result.skipped],
  );
  final report = formatHookReport(all, spill: (name, text) => saveSpill(root, Spill.fileName('$stamp-$name'), text));
  var next = now;
  if (result.formatted.isNotEmpty) {
    try {
      next = await GitService.snapshotTree(target);
    } on Object {
      // The rewritten files are checked again next time.
    }
  }
  return (report: report, skipped: hookSkips(all), tree: next);
}
