// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:io';

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

// Process.start rather than Process.run(...).timeout, which would leave a
// stuck CLI (a stopped VM's) running.
Future<CommandResult?> _run(
  String executable,
  List<String> args, {
  Duration timeout = const Duration(seconds: 3),
  Map<String, String> environment = const {},
}) async {
  try {
    final shell = await ShellEnv.load();
    final process = await Process.start(executable, args, environment: {...shell.env, ...environment});
    unawaited(process.stdin.close());
    unawaited(process.stderr.drain<void>());
    final out = <int>[];
    final done = process.stdout.forEach(out.addAll);
    final int code;
    try {
      code = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      return null;
    }
    // A child that keeps stdout open (an ssh master) mustn't hold the answer.
    await done.timeout(const Duration(seconds: 1), onTimeout: () {});
    return (code: code, stdout: out);
  } on Object {
    return null;
  }
}
