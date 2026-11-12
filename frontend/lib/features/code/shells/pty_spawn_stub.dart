// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../../../core/process/supervisor.dart' show ProcessOwner, ProcessSupervisor;
import '../panes/pty.dart' show ShellPty;

/// Starts [executable] in a pseudo-terminal. Platforms without `dart:ffi` (the web) have no ptys: always null, so
/// callers fall back to pipes.
typedef PtySpawner = Future<ShellPty?> Function(
  String executable,
  List<String> args,
  String cwd,
  Map<String, String> env,
  int rows,
  int cols, {
  required ProcessSupervisor supervisor,
  required ProcessOwner owner,
  String? label,
});

Future<ShellPty?> spawnPty(
  String executable,
  List<String> args,
  String cwd,
  Map<String, String> env,
  int rows,
  int cols, {
  required ProcessSupervisor supervisor,
  required ProcessOwner owner,
  String? label,
}) async => null;
