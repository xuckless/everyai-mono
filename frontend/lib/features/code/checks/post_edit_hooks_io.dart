// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../domain/spill.dart';
import '../git/git_service.dart';
import '../git/git_service_io.dart' show runGit;
import '../harness/everyai/shell_io.dart';
import '../spill/spill.dart';
import 'post_edit_hooks.dart';

/// Runs the fast after-edit checks on the files of [workingDir] that changed
/// in [target] since snapshot [tree] (null: since the session's base) and
/// that the lead touched ([touched]: what only the user changed is left
/// alone, and auto-format writes only the files the lead wrote). Each
/// command passes [refusal] first and runs in a [SessionShell] tagged
/// [sessionTag]; [cancel] stops the round. Returns the report for the lead
/// ('' when clean), the tools that did not run ('' when all did), the slow
/// project-wide checks still to run ([runSlowHooks]), and the snapshot the
/// next run compares with: taken before the checks, or after them when
/// auto-format wrote, so its writes are not checked again (the old one when
/// git failed or the round was cancelled).
Future<({String report, String skipped, String? tree, List<HookRun> slow})> runPostEditHooks({
  required String workingDir,
  required String sessionTag,
  required String shellDir,
  required SessionWorktree target,
  required String? tree,
  required String? Function(String command) refusal,
  required bool autoFormat,
  required TouchedPaths touched,
  Future<void>? cancel,
}) async {
  const none = <HookRun>[];
  final List<String> changed;
  final String top, now;
  try {
    // One snapshot, compared with the last: no second pass over the whole folder.
    now = await GitService.snapshotTree(target);
    top = (await runGit(target.path, ['rev-parse', '--show-toplevel'])).stdout.toString().trim();
  } on Object {
    return (report: '', skipped: '', tree: tree, slow: none);
  }
  try {
    changed = await GitService.changedBetween(target, tree ?? target.baseCommit, now);
  } on Object {
    // The old snapshot is gone (git pruned it): start again from this one.
    return (report: '', skipped: '', tree: now, slow: none);
  }
  // git names the top folder with its links resolved (/private/var on macOS), so compare it that way.
  final String root;
  try {
    root = Directory(workingDir).resolveSymbolicLinksSync();
  } on Object {
    return (report: '', skipped: '', tree: now, slow: none);
  }
  bool exists(String p) => FileSystemEntity.typeSync('$root/$p') != FileSystemEntityType.notFound;
  // What changed, as the session folder sees it (the lead's or not): git names paths from the top of the repository.
  final local = [
    for (final p in changed)
      if ('$top/$p' case final abs when top.isNotEmpty && abs.startsWith('$root/')) abs.substring(root.length + 1),
  ];
  final files = touchedOf([
    for (final rel in local)
      if (!rel.startsWith('.everyai/') && exists(rel)) rel,
  ], touched);
  if (files.isEmpty) return (report: '', skipped: '', tree: now, slow: none);
  String? read(String p) {
    try {
      return File('$root/$p').readAsStringSync();
    } on Object {
      return null;
    }
  }

  var found = detectHooks(files, exists: exists, read: read, autoFormat: autoFormat, writable: touched.written);
  // Projects whose node_modules git tracks: their binaries are repository code.
  final nodeDirs = {
    for (final r in found.runs)
      if (r.command.startsWith('node_modules/')) r.dir,
  };
  if (nodeDirs.isNotEmpty) {
    final tracked = <String>{};
    for (final d in nodeDirs) {
      try {
        // Guarded: the repository's own programs (core.fsmonitor) don't run.
        final r = await runGit(d.isEmpty ? root : '$root/$d', ['ls-files', '--', 'node_modules']);
        if (r.exitCode != 0 || r.stdout.toString().trim().isNotEmpty) tracked.add(d);
      } on Object {
        tracked.add(d);
      }
    }
    if (tracked.isNotEmpty) {
      found = detectHooks(
        files,
        exists: exists,
        read: read,
        autoFormat: autoFormat,
        writable: touched.written,
        nodeModulesTracked: tracked.contains,
      );
    }
  }
  // node_modules binaries that changed since the last round (untracked, not ignored) or that the lead's calls wrote:
  // they still run (the user's installed tools), but the lead is told which ones it may have written.
  final binNotes = <String>[];
  for (final d in {
    for (final r in found.runs)
      if (r.command.startsWith('node_modules/')) r.dir,
  }) {
    final under = d.isEmpty ? 'node_modules/' : '$d/node_modules/';
    final wrote = {
      for (final p in [...local, ...touched.written, ...touched.named])
        if (p.startsWith(under)) p,
    }.toList()..sort();
    if (wrote.isEmpty) continue;
    binNotes.add(
      'Note: ${wrote.take(8).join(', ')}${wrote.length > 8 ? ' and ${wrote.length - 8} more' : ''} under '
      '${under.substring(0, under.length - 1)} changed in this session and git does not track '
      '${wrote.length == 1 ? 'it' : 'them'}; the checks ran that folder\'s tools anyway.',
    );
  }
  final shell = SessionShell(root: root, sessionTag: sessionTag, scratchDir: shellDir);
  var cancelled = false;
  unawaited(cancel?.then((_) => cancelled = true));
  final result = await runHooks(
    [
      for (final r in found.runs)
        if (!r.slow) r,
    ],
    run: (command, stop) async {
      final r = await shell.run(command, timeout: hookCap, cancel: stop);
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
    cancel: cancel,
  );
  if (cancelled) return (report: '', skipped: '', tree: tree, slow: none);
  final stamp = DateTime.now().millisecondsSinceEpoch;
  final HookReport all = (
    problems: result.problems,
    formatted: result.formatted,
    skipped: [...found.skipped, ...result.skipped],
  );
  final report = [
    ...binNotes,
    formatHookReport(all, spill: (name, text) => saveSpill(root, Spill.fileName('$stamp-$name'), text)),
  ].where((s) => s.isNotEmpty).join('\n\n');
  var next = now;
  if (result.formatted.isNotEmpty) {
    try {
      next = await GitService.snapshotTree(target);
    } on Object {
      // The rewritten files are checked again next time.
    }
  }
  return (
    report: report,
    skipped: hookSkips(all),
    tree: next,
    slow: [
      for (final r in found.runs)
        if (r.slow) r,
    ],
  );
}

/// Runs the slow project-wide checks [runs] (from [runPostEditHooks]) in
/// [workingDir], within [slowHookCap]; [baselines] (see [runHooks]) is kept
/// by the caller across rounds. Returns the report ('' when clean or
/// cancelled) and the tools that did not run.
Future<({String report, String skipped})> runSlowHooks({
  required String workingDir,
  required String sessionTag,
  required String shellDir,
  required List<HookRun> runs,
  required String? Function(String command) refusal,
  required Map<String, List<String>> baselines,
  Future<void>? cancel,
}) async {
  if (runs.isEmpty) return (report: '', skipped: '');
  final String root;
  try {
    root = Directory(workingDir).resolveSymbolicLinksSync();
  } on Object {
    return (report: '', skipped: '');
  }
  final shell = SessionShell(root: root, sessionTag: sessionTag, scratchDir: shellDir);
  var cancelled = false;
  unawaited(cancel?.then((_) => cancelled = true));
  final result = await runHooks(
    runs,
    run: (command, stop) async {
      final r = await shell.run(command, timeout: slowHookCap, cancel: stop);
      return (exit: r.exitCode, out: r.output);
    },
    refusal: refusal,
    cap: slowHookCap,
    cancel: cancel,
    baselines: baselines,
  );
  if (cancelled) return (report: '', skipped: '');
  final stamp = DateTime.now().millisecondsSinceEpoch;
  return (
    report: formatHookReport(
      result,
      slow: true,
      spill: (name, text) => saveSpill(root, Spill.fileName('$stamp-slow-$name'), text),
    ),
    skipped: hookSkips(result),
  );
}
