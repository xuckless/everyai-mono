// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../git/git_models.dart';
import 'post_edit_hooks.dart';

// Web and mobile have no project folder to check.

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
}) async => (report: '', skipped: '', tree: tree, slow: const <HookRun>[]);

Future<({String report, String skipped})> runSlowHooks({
  required String workingDir,
  required String sessionTag,
  required String shellDir,
  required List<HookRun> runs,
  required String? Function(String command) refusal,
  required Map<String, List<String>> baselines,
  Future<void>? cancel,
}) async => (report: '', skipped: '');
