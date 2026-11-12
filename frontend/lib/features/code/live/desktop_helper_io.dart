// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'package:flutter/foundation.dart' show debugPrint;

import '../../../core/process/supervisor.dart';
import '../git/git_service.dart';

/// The desktop window helper for this computer, as the command that runs it: macOS `everyai-ax` (bundled, or a dev
/// build), Linux `python3 everyai_x11.py`, Windows `everyai-win.exe` (compiled on first use with the .NET Framework
/// compiler every Windows has). The Linux and Windows sources ship as assets (`assets/helpers/`) and are installed
/// under the app's data folder, named by their content, so an update installs the new one. EVERYAI_DESKTOP_HELPER
/// points at a helper to use instead (a .py on Linux, an .exe on Windows, the binary on macOS). Null when this
/// computer can't run one (no python3 or libX11 on Linux, no compiler on Windows): why is in [desktopHelperProblem].
Future<List<String>?> desktopHelper() => _helper ??= _find().then((h) {
  if (h == null) _helper = null; // Try again next time (python3 may get installed).
  return h;
});

Future<List<String>?>? _helper;

/// Why there's no desktop helper on this computer, after [desktopHelper] answered null.
String? desktopHelperProblem;

Future<List<String>?> _find() async {
  final set = Platform.environment['EVERYAI_DESKTOP_HELPER'] ?? Platform.environment['EVERYAI_AX_HELPER'];
  if (Platform.isMacOS) {
    final exe = File(Platform.resolvedExecutable).parent.path;
    for (final p in [
      ?set,
      '$exe/../Resources/everyai-ax',
      '${Directory.current.path}/.tools/everyai-ax',
      '${Directory.current.path}/frontend/.tools/everyai-ax',
    ]) {
      if (File(p).existsSync()) return [File(p).absolute.path];
    }
    desktopHelperProblem = 'The desktop window helper (everyai-ax) is missing from this build of EveryAI.';
    return null;
  }
  if (Platform.isLinux) {
    final python = await _which('python3');
    if (python == null) {
      desktopHelperProblem = 'Desktop windows on Linux need python3, which is not installed.';
      return null;
    }
    final script = set ?? await _install('everyai_x11.py', (src, out) async => File(out).writeAsString(src));
    return script == null ? null : [python, script];
  }
  if (Platform.isWindows) {
    final exe = set ?? await _install('everyai_win.cs', _compileWindows, extension: '.exe');
    return exe == null ? null : [exe];
  }
  desktopHelperProblem = 'Desktop windows are not supported on this system.';
  return null;
}

Future<String?> _which(String name) async {
  for (final dir in (Platform.environment['PATH'] ?? '/usr/bin:/bin').split(':')) {
    final f = File('$dir/$name');
    if (f.existsSync()) return f.path;
  }
  return null;
}

/// Installs asset [name] (through [build], which writes the runnable file) under the data folder, once per content.
Future<String?> _install(
  String name,
  Future<void> Function(String source, String out) build, {
  String? extension,
}) async {
  try {
    final source = await rootBundle.loadString('assets/helpers/$name');
    final digest = sha256.convert(utf8.encode(source)).toString().substring(0, 12);
    final dir = Directory('${await GitService.dataDir()}/tools')..createSync(recursive: true);
    final stem = name.substring(0, name.lastIndexOf('.'));
    final out = '${dir.path}/$stem-$digest${extension ?? name.substring(name.lastIndexOf('.'))}';
    if (!File(out).existsSync()) await build(source, out);
    return out;
  } on Object catch (e) {
    desktopHelperProblem = 'The desktop window helper could not be set up: $e';
    return null;
  }
}

/// Compiles the Windows helper with the .NET Framework 4 C# compiler (C# 5) that ships with Windows.
Future<void> _compileWindows(String source, String out) async {
  final windir = Platform.environment['WINDIR'] ?? Platform.environment['SystemRoot'] ?? r'C:\Windows';
  String? fw;
  for (final d in [
    '$windir\\Microsoft.NET\\Framework64\\v4.0.30319',
    '$windir\\Microsoft.NET\\Framework\\v4.0.30319',
  ]) {
    if (File('$d\\csc.exe').existsSync()) {
      fw = d;
      break;
    }
  }
  if (fw == null) throw StateError('the .NET Framework 4 compiler (csc.exe) was not found');
  final src = '$out.cs';
  File(src).writeAsStringSync(source);
  try {
    final r = await ProcessSupervisor.instance.runBounded(
      '$fw\\csc.exe',
      [
        '/nologo',
        '/target:exe',
        '/optimize+',
        '/out:$out',
        '/r:System.Drawing.dll',
        '/r:$fw\\WPF\\UIAutomationClient.dll',
        '/r:$fw\\WPF\\UIAutomationTypes.dll',
        '/r:$fw\\WPF\\WindowsBase.dll',
        src,
      ],
      timeout: const Duration(minutes: 2),
      owner: const ProbeOwner('desktop-helper'),
      label: 'compile the Windows window helper',
    );
    switch (r) {
      case Finished(:final code, :final stdout, :final stderr) when code != 0 || !File(out).existsSync():
        throw StateError('compiling it failed: ${'$stdout$stderr'.trim()}');
      case Finished():
        break;
      case TimedOut(:final kill) || Cancelled(:final kill):
        if (File(out).existsSync()) File(out).deleteSync();
        throw StateError('compiling it took over 2 minutes (${kill is Ended ? 'stopped' : 'NOT closed: $kill'})');
      case StartFailed(:final error):
        throw StateError('the compiler could not start: $error');
    }
  } finally {
    try {
      File(src).deleteSync();
    } on Object {
      // Left behind: harmless.
    }
  }
}

/// Every process on Windows as pid → parent pid (through the helper; empty when it isn't available).
Future<Map<int, int>> windowsParents() async {
  final cmd = await desktopHelper();
  if (cmd == null) return const {};
  final r = await ProcessSupervisor.instance.runBounded(
    cmd.first,
    [...cmd.skip(1), 'procs'],
    timeout: const Duration(seconds: 10),
    owner: const ProbeOwner('desktop-helper'),
    stdoutEncoding: utf8,
    label: 'window helper procs',
  );
  switch (r) {
    case Finished(:final code, :final stdout) when code == 0:
      try {
        return {
          for (final p in (jsonDecode(stdout) as List).whereType<Map<String, Object?>>())
            (p['pid'] as num).toInt(): (p['ppid'] as num).toInt(),
        };
      } on Object catch (e) {
        debugPrint('The window helper\'s process list did not parse: $e');
        return const {};
      }
    case Finished() || TimedOut() || Cancelled() || StartFailed():
      debugPrint('The window helper could not list processes: $r');
      return const {};
  }
}
