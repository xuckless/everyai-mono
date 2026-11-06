// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../git/git_models.dart';

// Web and mobile have no project folder to check.

Future<({String report, String skipped, String? tree})> runPostEditHooks({
  required String workingDir,
  required String sessionTag,
  required String shellDir,
  required SessionWorktree target,
  required String? tree,
  required String? Function(String command) refusal,
  required bool autoFormat,
}) async => (report: '', skipped: '', tree: tree);
