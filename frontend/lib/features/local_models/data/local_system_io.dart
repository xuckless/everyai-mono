// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../code/drivers/acp/acp_files.dart' show whichCommand;
import '../domain/fm.dart';
import '../domain/hardware.dart';
import 'hardware_scan.dart';
import 'local_system.dart';

LocalSystem createLocalSystem() => IoLocalSystem();

const fmPath = '/usr/bin/fm';

/// The real computer.
final class IoLocalSystem implements LocalSystem {
  IoLocalSystem({LocalRun? run}) : _run = run ?? runProgram;

  final LocalRun _run;
  final _started = <Process>[];

  @override
  HostOs get os => Platform.isMacOS
      ? HostOs.macos
      : Platform.isWindows
      ? HostOs.windows
      : Platform.isLinux
      ? HostOs.linux
      : HostOs.other;

  @override
  Future<HardwareSpec> hardware() => scanHardwareWith(
    os: os,
    run: _run,
    readFile: (p) async {
      try {
        return await File(p).readAsString();
      } on Object {
        return null;
      }
    },
    diskPath: ollamaModelsDir(),
  );

  @override
  Future<String?> ollamaPath() async {
    final onPath = await whichCommand(Platform.isWindows ? 'ollama.exe' : 'ollama').catchError((_) => null);
    if (onPath != null) return onPath;
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
    final local = Platform.environment['LOCALAPPDATA'] ?? '';
    final candidates = [
      if (Platform.isMacOS) ...[
        '/Applications/Ollama.app/Contents/Resources/ollama',
        '$home/Applications/Ollama.app/Contents/Resources/ollama',
        '/opt/homebrew/bin/ollama',
        '/usr/local/bin/ollama',
      ],
      if (Platform.isLinux) ...['/usr/local/bin/ollama', '/usr/bin/ollama', '$home/.local/bin/ollama'],
      if (Platform.isWindows) '$local\\Programs\\Ollama\\ollama.exe',
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  @override
  Future<bool> startOllama(String path) async {
    try {
      final p = await Process.start(path, const ['serve'], environment: {'EVERYAI_LOCAL_SERVER': '1'});
      _drain(p);
      _started.add(p);
      return true;
    } on Object {
      return false;
    }
  }

  @override
  Future<FmStatus> fmStatus() async {
    if (!Platform.isMacOS || !File(fmPath).existsSync()) return FmStatus.missing;
    final licence = await _run(fmPath, const ['license', '--status']);
    final agreed = licence == null ? null : parseFmLicence(licence.out);
    if (agreed != true) {
      return FmStatus(
        FmState.needsLicence,
        path: fmPath,
        detail: licence == null ? null : stripAnsi(licence.out).trim(),
      );
    }
    final models = await _run(fmPath, const ['models']);
    if (models != null && parseFmUnsupported(models.out)) {
      return FmStatus(FmState.unsupported, path: fmPath, detail: stripAnsi(models.out).trim());
    }
    return const FmStatus(FmState.ready, path: fmPath);
  }

  @override
  Future<int?> startFm() async {
    try {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      final p = await Process.start(fmPath, ['serve', '--host', '127.0.0.1', '--port', '$port']);
      _drain(p);
      _started.add(p);
      return port;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> stopStarted() async {
    for (final p in _started) {
      p.kill();
    }
    _started.clear();
  }

  /// Their output is read and dropped, so a full pipe never stalls them.
  void _drain(Process p) {
    p.stdout.listen((_) {}, onError: (_) {});
    p.stderr.listen((_) {}, onError: (_) {});
  }
}

/// Where Ollama keeps models: `OLLAMA_MODELS`, else `~/.ollama/models` (or the home when that isn't there yet).
String ollamaModelsDir() {
  final env = Platform.environment;
  final set = env['OLLAMA_MODELS'];
  if (set != null && set.isNotEmpty) return set;
  final home = env['HOME'] ?? env['USERPROFILE'] ?? '.';
  final dir = Platform.isWindows ? '$home\\.ollama\\models' : '$home/.ollama/models';
  return Directory(dir).existsSync() ? dir : home;
}

/// [LocalRun] with dart:io, 10 s at most.
Future<({int code, String out})?> runProgram(String exe, List<String> args) async {
  try {
    final r = await Process.run(exe, args, stdoutEncoding: utf8).timeout(const Duration(seconds: 10));
    return (code: r.exitCode, out: '${r.stdout}');
  } on Object {
    return null;
  }
}
