// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/code_session.dart';
import 'post_edit_hooks.dart';
import 'post_edit_hooks_stub.dart' if (dart.library.io) 'post_edit_hooks_io.dart' as impl;

/// What a round of the fast after-edit checks gave: the note for the lead's
/// next message ('' when clean), the tools that did not run ('' when all
/// did), the tree the next round compares with, and the slow project-wide
/// checks still to run ([slowHooksProvider]).
typedef HookRound = ({String report, String skipped, String tree, List<HookRun> slow});

/// Runs the fast after-edit checks for session [info] on what changed since
/// [CodeSessionInfo.checkedTree] (its base before the first run) and the
/// lead [touched]. [shellDir] finds the session's scratch folder for the
/// shell, [refusal] why a command won't run, [autoFormat] whether formatters
/// write; [cancel] stops the round (the tree then stays).
typedef PostEditHooks = Future<HookRound> Function(
  CodeSessionInfo info, {
  required Future<String> Function() shellDir,
  required String? Function(String command) refusal,
  required bool autoFormat,
  required TouchedPaths touched,
  Future<void>? cancel,
});

/// Runs slow checks [runs] for session [info] in the background; [baselines]
/// is the session's memory of their last output (see [runHooks]).
typedef SlowHooks = Future<({String report, String skipped})> Function(
  CodeSessionInfo info,
  List<HookRun> runs, {
  required Future<String> Function() shellDir,
  required String? Function(String command) refusal,
  required Map<String, List<String>> baselines,
  Future<void>? cancel,
});

/// The checks; tests override it with a fake.
final postEditHooksProvider = Provider<PostEditHooks>((ref) {
  return (info, {required shellDir, required refusal, required autoFormat, required touched, cancel}) async {
    final target = info.diffTarget;
    if (target == null) return (report: '', skipped: '', tree: info.checkedTree, slow: const <HookRun>[]);
    final r = await impl.runPostEditHooks(
      workingDir: info.workingDir,
      sessionTag: info.id,
      shellDir: await shellDir(),
      target: target,
      tree: info.checkedTree.isEmpty ? null : info.checkedTree,
      refusal: refusal,
      autoFormat: autoFormat,
      touched: touched,
      cancel: cancel,
    );
    return (report: r.report, skipped: r.skipped, tree: r.tree ?? info.checkedTree, slow: r.slow);
  };
});

/// The slow checks; tests override it with a fake.
final slowHooksProvider = Provider<SlowHooks>((ref) {
  return (info, runs, {required shellDir, required refusal, required baselines, cancel}) async {
    if (info.diffTarget == null || runs.isEmpty) return (report: '', skipped: '');
    return impl.runSlowHooks(
      workingDir: info.workingDir,
      sessionTag: info.id,
      shellDir: await shellDir(),
      runs: runs,
      refusal: refusal,
      baselines: baselines,
      cancel: cancel,
    );
  };
});
