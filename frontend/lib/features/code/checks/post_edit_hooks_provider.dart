// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/code_session.dart';
import 'post_edit_hooks_stub.dart' if (dart.library.io) 'post_edit_hooks_io.dart' as impl;

/// Runs the after-edit checks for session [info] on what changed since
/// [CodeSessionInfo.checkedTree] (its base before the first run). Returns the
/// note for the lead's next message ('' when clean), the tools that did not
/// run ('' when all did) and the tree the next run compares with.
/// [shellDir] finds the session's scratch folder for the shell, [refusal]
/// why a command won't run, [autoFormat] whether formatters write.
typedef PostEditHooks = Future<({String report, String skipped, String tree})> Function(
  CodeSessionInfo info, {
  required Future<String> Function() shellDir,
  required String? Function(String command) refusal,
  required bool autoFormat,
});

/// The checks; tests override it with a fake.
final postEditHooksProvider = Provider<PostEditHooks>((ref) {
  return (info, {required shellDir, required refusal, required autoFormat}) async {
    final target = info.diffTarget;
    if (target == null) return (report: '', skipped: '', tree: info.checkedTree);
    final r = await impl.runPostEditHooks(
      workingDir: info.workingDir,
      sessionTag: info.id,
      shellDir: await shellDir(),
      target: target,
      tree: info.checkedTree.isEmpty ? null : info.checkedTree,
      refusal: refusal,
      autoFormat: autoFormat,
    );
    return (report: r.report, skipped: r.skipped, tree: r.tree ?? info.checkedTree);
  };
});
