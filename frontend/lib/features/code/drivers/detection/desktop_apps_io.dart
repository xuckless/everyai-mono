// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';

import '../../../../core/process/supervisor.dart';
import '../short_run.dart';
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

/// `reg query` output, or '' when it fails or runs past 3 s (then it is stopped, verified).
Future<String> _reg(String executable, List<String> args) async {
  final r = await runShort(
    executable,
    args,
    timeout: const Duration(seconds: 3),
    owner: const ProbeOwner('desktop-apps'),
  );
  switch (r) {
    case Finished(code: 0, :final stdout):
      return stdout;
    case TimedOut(:final kill) || Cancelled(:final kill):
      logStop('$executable ${args.join(' ')}', kill);
      return '';
    case Finished() || StartFailed() || Refused():
      return '';
  }
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
