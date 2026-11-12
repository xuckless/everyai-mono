// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';

import '../../../core/process/supervisor.dart';
import '../drivers/short_run.dart';

import '../drivers/driver_process_io.dart' show findOnPath;
import '../harness/everyai/shell_io.dart' show ShellEnv;
import 'discovery.dart';

/// This computer: CLIs found and run with the login shell's environment.
EnvironmentIo platformEnvironmentIo() => EnvironmentIo(
  run: _run,
  which: _which,
  os: Platform.isMacOS
      ? HostOs.macos
      : Platform.isWindows
      ? HostOs.windows
      : Platform.isLinux
      ? HostOs.linux
      : HostOs.other,
  home: (Platform.isWindows ? Platform.environment['USERPROFILE'] : Platform.environment['HOME']) ?? '',
  readFile: (path) {
    try {
      return File(path).readAsStringSync();
    } on Object {
      return null;
    }
  },
  exists: (path) => FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound,
  listDir: (dir) {
    try {
      return [for (final e in Directory(dir).listSync()) e.uri.pathSegments.lastWhere((s) => s.isNotEmpty)];
    } on Object {
      return const [];
    }
  },
  wslEnv: Platform.environment['WSLENV'] ?? '',
);

String get _pathKey => Platform.isWindows
    ? Platform.environment.keys.firstWhere((k) => k.toUpperCase() == 'PATH', orElse: () => 'Path')
    : 'PATH';

Future<String?> _which(String command) async => findOnPath(command, (await ShellEnv.load()).env[_pathKey] ?? '');

/// Through the supervisor: a stuck CLI (a stopped VM's) is stopped with what it started when [timeout] runs out
/// (null then, as for a program that isn't there). What it started that still holds its output (an ssh master)
/// is stopped too once it has exited.
Future<CommandResult?> _run(
  String executable,
  List<String> args, {
  Duration timeout = const Duration(seconds: 3),
  Map<String, String> environment = const {},
}) async {
  final ShellEnv shell;
  try {
    shell = await ShellEnv.load();
  } on Object {
    return null;
  }
  final r = await runShort(
    executable,
    args,
    timeout: timeout,
    env: {...shell.env, ...environment},
    owner: const ProbeOwner('environments'),
    stdin: '',
  );
  return switch (r) {
    Finished(:final code, :final stdoutBytes) => (code: code, stdout: stdoutBytes),
    TimedOut() || Cancelled() || StartFailed() || Refused() => _failed(executable, r),
  };
}

CommandResult? _failed(String executable, RunResult r) {
  if (r case TimedOut(:final kill) || Cancelled(:final kill)) logStop(executable, kill);
  return null;
}
