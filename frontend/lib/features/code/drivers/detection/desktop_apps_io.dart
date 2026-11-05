// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'desktop_apps.dart';

List<String> _listDir(String dir) {
  try {
    return [for (final e in Directory(dir).listSync()) e.path.split(Platform.pathSeparator).last];
  } on Object {
    return const [];
  }
}

String? _readFile(String path) {
  try {
    return File(path).readAsStringSync();
  } on Object {
    return null;
  }
}

Future<String> _reg(String executable, List<String> args) async {
  final proc = await Process.start(executable, args);
  final out = proc.stdout.transform(utf8.decoder).join();
  unawaited(proc.stderr.drain<void>());
  // Killed when it runs out (`Process.run(...).timeout` would leave it running).
  final code = await proc.exitCode.timeout(
    const Duration(seconds: 3),
    onTimeout: () {
      proc.kill();
      return -1;
    },
  );
  return code == 0 ? await out : '';
}

String get _home => Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';

/// [scanDesktopApps] on this computer.
Future<AppScan> scanHere() => scanDesktopApps(
  os: Platform.operatingSystem,
  home: _home,
  env: Platform.environment,
  listDir: _listDir,
  readFile: _readFile,
  run: _reg,
);

/// [bundledCliPaths] on this computer ([isFile] is for tests).
List<String> bundledHere(String command, {bool Function(String path)? isFile}) => bundledCliPaths(
  command,
  os: Platform.operatingSystem,
  home: _home,
  env: Platform.environment,
  listDir: _listDir,
  isFile: isFile ?? (p) => File(p).existsSync(),
);
