// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

// Web and mobile run no commands, so nothing is timed.

Future<void> recordRuntime(String projectRoot, String command, String dir, Duration took) async {}

Future<List<String>> sessionRuntimeProfiles(String sessionDir, String projectRoot) async => const [];
