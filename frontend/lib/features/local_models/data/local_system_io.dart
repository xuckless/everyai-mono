// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:io' as io show pid;

import 'package:path_provider/path_provider.dart';

import '../../code/drivers/acp/acp_files.dart' show whichCommand;
import '../../code/harness/everyai/shell_io.dart' show killTree;
import '../domain/fm.dart';
import '../domain/hardware.dart';
import 'hardware_scan.dart';
import 'local_system.dart';

LocalSystem createLocalSystem() => IoLocalSystem();

const fmPath = fmExecutable;

/// The real computer.
final class IoLocalSystem implements LocalSystem {
  IoLocalSystem({LocalRun? run}) : _run = run ?? runProgram;

  final LocalRun _run;

  /// Server processes EveryAI launched, by server id.
  final _owned = <String, Process>{};

  /// Ids launched through the shell (a user's start command): the server may be the shell's child, so a stop ends
  /// the whole tree while the shell still runs.
  final _viaShell = <String>{};
  String? _launchProblem;

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
    final home = _home;
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
    return candidates.where((c) => File(c).existsSync()).firstOrNull;
  }

  @override
  Future<String?> lmsPath() async {
    final onPath = await whichCommand(Platform.isWindows ? 'lms.exe' : 'lms').catchError((_) => null);
    if (onPath != null) return onPath;
    final bundled = Platform.isWindows ? '$_home\\.lmstudio\\bin\\lms.exe' : '$_home/.lmstudio/bin/lms';
    return File(bundled).existsSync() ? bundled : null;
  }

  static String get _home => Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';

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
  Future<({int code, String out})?> run(String exe, List<String> args) => _run(exe, args);

  @override
  String? get launchProblem => _launchProblem;

  @override
  Future<LaunchedServer?> launch(
    String id,
    String exe,
    List<String> args, {
    Map<String, String> env = const {},
    bool shell = false,
    String? logPath,
  }) async {
    _launchProblem = null;
    if (_owned.containsKey(id)) {
      _launchProblem = 'It is already running.';
      return null;
    }
    final Process p;
    try {
      p = shell
          ? (Platform.isWindows
                ? await Process.start('cmd.exe', ['/c', exe], environment: {...env, 'EVERYAI_LOCAL_SERVER': id})
                : await Process.start(
                    '/bin/sh',
                    ['-c', shellStartCommand(exe)],
                    environment: {...env, 'EVERYAI_LOCAL_SERVER': id},
                  ))
          : await Process.start(exe, args, environment: {...env, 'EVERYAI_LOCAL_SERVER': id});
    } on Object catch (e) {
      _launchProblem = "Couldn't start it: $e";
      return null;
    }
    _owned[id] = p;
    if (shell) {
      _viaShell.add(id);
    } else {
      _viaShell.remove(id);
    }
    IOSink? log;
    if (logPath != null) {
      try {
        await File(logPath).parent.create(recursive: true);
        log = File(logPath).openWrite(mode: FileMode.append);
      } on Object {
        log = null;
      }
    }
    // Read even without a log: a full pipe would stall the server.
    p.stdout.listen((d) => log?.add(d), onError: (_) {});
    p.stderr.listen((d) => log?.add(d), onError: (_) {});
    final exited = p.exitCode.then((code) async {
      if (identical(_owned[id], p)) _owned.remove(id);
      await log?.close().catchError((Object _) {});
      return code;
    });
    return LaunchedServer(pid: p.pid, exited: exited);
  }

  @override
  bool owns(String id) => _owned.containsKey(id);

  @override
  Future<String?> stopOwned(String id, {Duration grace = const Duration(seconds: 5)}) async {
    final p = _owned[id];
    if (p == null) return null;
    if (_viaShell.contains(id)) {
      // A shell (or cmd.exe) with the server below it: signalling the shell alone would orphan the server. The tree
      // is listed while the shell still runs (its pid is still its own), then ended: TERM, KILL a moment later.
      await killTree(p.pid, termWait: grace > const Duration(seconds: 2) ? const Duration(seconds: 2) : grace);
      final code = await p.exitCode.timeout(const Duration(seconds: 2), onTimeout: () => -999);
      return code == -999 ? "It didn't stop (pid ${p.pid})." : null;
    }
    Process.killPid(p.pid, ProcessSignal.sigterm);
    final code = await p.exitCode.timeout(grace, onTimeout: () => -999);
    if (code != -999) return null;
    // Didn't end in time: it and its children, by force.
    await killTree(p.pid);
    final forced = await p.exitCode.timeout(const Duration(seconds: 2), onTimeout: () => -999);
    return forced == -999 ? "It didn't stop (pid ${p.pid})." : null;
  }

  @override
  Future<String?> stopListener(int port, {Duration grace = const Duration(seconds: 5)}) async {
    final found = await listenerOf(port);
    if (found == null) return null;
    final (:pid, :command) = found;
    if (pid == io.pid || command.contains('everyai-backend')) return "That's EveryAI's own server.";
    for (final e in _owned.entries) {
      if (e.value.pid == pid) return stopOwned(e.key, grace: grace);
    }
    // Ollama's menu-bar app restarts a server it lost: quit the app instead.
    if (Platform.isMacOS && command.contains('/Ollama.app/')) {
      await _run('/usr/bin/osascript', const ['-e', 'quit app "Ollama"']);
    } else if (Platform.isWindows) {
      final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
      await _run('$root\\System32\\taskkill.exe', ['/PID', '$pid', '/T']);
    } else if (!Process.killPid(pid, ProcessSignal.sigterm)) {
      return command.contains('ollama')
          ? 'It runs as a system service. Stop it with `sudo systemctl stop ollama`.'
          : "EveryAI isn't allowed to stop it (it runs as another user).";
    }
    if (await _gone(port, grace)) return null;
    if (Platform.isWindows) {
      final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
      await _run('$root\\System32\\taskkill.exe', ['/PID', '$pid', '/T', '/F']);
    } else {
      Process.killPid(pid, ProcessSignal.sigkill);
    }
    return await _gone(port, const Duration(seconds: 2)) ? null : "It didn't stop (pid $pid).";
  }

  Future<bool> _gone(int port, Duration within) async {
    final until = DateTime.now().add(within);
    while (DateTime.now().isBefore(until)) {
      if (await listenerOf(port) == null) return true;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return await listenerOf(port) == null;
  }

  /// The process listening on loopback [port], with its command line, or null.
  Future<({int pid, String command})?> listenerOf(int port) async {
    int? pid;
    if (Platform.isWindows) {
      final r = await _run('netstat', const ['-ano', '-p', 'TCP']);
      pid = r == null ? null : parseNetstatListener(r.out, port);
    } else {
      final lsof = File('/usr/sbin/lsof').existsSync() ? '/usr/sbin/lsof' : 'lsof';
      final r = await _run(lsof, ['-nP', '-iTCP:$port', '-sTCP:LISTEN', '-t']);
      pid = r == null ? null : int.tryParse(r.out.trim().split('\n').first.trim());
    }
    if (pid == null) return null;
    final cmd = Platform.isWindows ? null : await _run('/bin/ps', ['-o', 'command=', '-p', '$pid']);
    return (pid: pid, command: cmd?.out.trim() ?? '');
  }

  @override
  Future<int?> freePort() async {
    try {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      return port;
    } on Object {
      return null;
    }
  }

  @override
  Future<String?> logDir() async {
    try {
      final dir = Directory('${(await getApplicationSupportDirectory()).path}/local-servers');
      await dir.create(recursive: true);
      return dir.path;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> stopAllOwned() async {
    await Future.wait([for (final id in _owned.keys.toList()) stopOwned(id, grace: const Duration(seconds: 2))]);
  }
}

/// The pid listening on [port] in `netstat -ano -p TCP` output (Windows), or null.
int? parseNetstatListener(String out, int port) {
  for (final line in out.split('\n')) {
    final cols = line.trim().split(RegExp(r'\s+'));
    if (cols.length < 5 || cols[0] != 'TCP' || cols[3] != 'LISTENING') continue;
    if (cols[1].endsWith(':$port')) return int.tryParse(cols[4]);
  }
  return null;
}

/// A user's start command as `/bin/sh -c` runs it: a single command is `exec`ed, so the server takes the shell's
/// pid and a stop reaches it directly. Commands with shell syntax stay as they are (a stop ends the shell's tree).
String shellStartCommand(String command) {
  final c = command.trim();
  if (c.startsWith('exec ')) return c;
  // Anything that needs the shell to keep running (lists, pipes, background jobs, subshells, redirections into
  // compound commands, assignments) is left alone.
  if (RegExp(r'[;&|()`\n]|\$\(').hasMatch(c)) return c;
  if (RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=').hasMatch(c)) return c;
  if (RegExp(r'^(cd|export|source|\.|if|for|while|case|until)\b').hasMatch(c)) return c;
  return 'exec $c';
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

bool get runningUnderTest => Platform.environment['FLUTTER_TEST'] == 'true';
