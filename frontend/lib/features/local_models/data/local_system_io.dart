// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:io' as io show pid;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

import '../../../core/process/supervisor.dart';
import '../../code/drivers/acp/acp_files.dart' show whichCommand;
import '../domain/fm.dart';
import '../domain/hardware.dart';
import '../domain/local_server.dart';
import 'hardware_scan.dart';
import 'local_system.dart';

LocalSystem createLocalSystem() => IoLocalSystem();

const fmPath = fmExecutable;

/// What the process ledger and the supervisor's registry call the process of server [id]: `local server ollama`,
/// with ` :<port>` when it serves one. The registry is the truth about which servers EveryAI started (a run reopened
/// after a hot restart takes its children back with their labels), so this is how they are found again.
String localServerLabel(String id, int? port) => 'local server $id${port == null ? '' : ' :$port'}';

/// [localServerLabel] read back; null for any other label.
({String id, int? port})? parseLocalServerLabel(String label) {
  final m = RegExp(r'^local server (\S+?)(?: :(\d+))?$').firstMatch(label);
  return m == null ? null : (id: m.group(1)!, port: m.group(2) == null ? null : int.parse(m.group(2)!));
}

/// The real computer. Every server process it starts is a child of the process supervisor (own process group,
/// ledger, verified stop); which servers are EveryAI's is read from the supervisor's registry, never kept here.
final class IoLocalSystem implements LocalSystem {
  IoLocalSystem({LocalRun? run, ProcessSupervisor? supervisor})
    : _run = run ?? ((exe, args) => runProgram(exe, args, supervisor: supervisor)),
      _supervisor = supervisor; // ignore: prefer_initializing_formals

  final LocalRun _run;
  final ProcessSupervisor? _supervisor;
  ProcessSupervisor get _sup => _supervisor ?? ProcessSupervisor.instance;
  String? _launchProblem;

  /// Server [id]'s process, while the supervisor lists it (running, stopping, or not closed).
  SupervisedChild? _child(String id) =>
      _sup.children.where((c) => c.state.live && parseLocalServerLabel(c.spec.label)?.id == id).firstOrNull;

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
    int? port,
  }) async {
    _launchProblem = null;
    if (_child(id) != null) {
      _launchProblem = 'It is already running.';
      return null;
    }
    final SupervisedProcess p;
    try {
      // A user's start command runs under the shell, which leads the process group the supervisor gives it: what
      // the command puts in the background stays in that group and ends with it.
      p = await _sup.spawn(
        SpawnSpec(
          owner: const AppOwner(),
          kind: ProcessKind.localServer,
          exe: shell ? (Platform.isWindows ? 'cmd.exe' : '/bin/sh') : exe,
          args: shell ? (Platform.isWindows ? ['/c', exe] : ['-c', shellStartCommand(exe)]) : args,
          env: {...env, 'EVERYAI_LOCAL_SERVER': id},
          label: localServerLabel(id, port),
          port: port,
          detail: shell ? 'start command: $exe' : null,
        ),
      );
    } on Object catch (e) {
      _launchProblem = "Couldn't start it: $e";
      return null;
    }
    IOSink? log;
    if (logPath != null) {
      try {
        await File(logPath).parent.create(recursive: true);
        log = File(logPath).openWrite(mode: FileMode.append);
      } on Object catch (e) {
        debugPrint('Local server $id: its log $logPath could not be opened ($e); output is dropped.');
        log = null;
      }
    }
    // Read even without a log: a full pipe would stall the server.
    void lost(Object e) => debugPrint('Local server $id: reading its output failed: $e');
    final outDone = p.stdout.listen((d) => log?.add(d)).asFuture<void>().catchError(lost);
    final errDone = p.stderr.listen((d) => log?.add(d)).asFuture<void>().catchError(lost);
    final exited = p.exitCode.then((code) async {
      await Future.wait([outDone, errDone]).timeout(const Duration(seconds: 1), onTimeout: () => const []);
      try {
        await log?.close();
      } on Object catch (e) {
        debugPrint('Local server $id: its log could not be closed: $e');
      }
      return code;
    });
    return LaunchedServer(pid: p.pid ?? 0, exited: exited);
  }

  @override
  bool owns(String id) => _child(id) != null;

  @override
  int? ownedPort(String id) => switch (_child(id)) {
    final c? => c.spec.port ?? parseLocalServerLabel(c.spec.label)?.port,
    null => null,
  };

  @override
  Future<ServerStopResult> stopOwned(String id, {Duration grace = const Duration(seconds: 5)}) async {
    final c = _child(id);
    if (c == null) return const ServerStopEnded();
    return _settled('Local server $id', await c.stop(timings: StopTimings(termGrace: grace)));
  }

  static ServerStopResult _settled(String what, KillOutcome outcome) {
    if (outcome is Ended) return ServerStopEnded(outcome);
    debugPrint('NOT CLOSED: $what: $outcome');
    return ServerStopNotClosed(outcome);
  }

  @override
  Future<ServerStopResult> stopListener(
    LocalServer server, {
    required int port,
    Duration grace = const Duration(seconds: 5),
  }) async {
    if (!isLoopbackUrl(server.baseUrl)) {
      return ServerStopRefused(
        '${server.label} is at ${Uri.tryParse(server.baseUrl)?.host ?? server.baseUrl}, not on this computer\'s '
        'loopback address: EveryAI only stops servers it can see here.',
      );
    }
    if (port <= 0) return const ServerStopRefused('It has no port.');
    final found = await _listener(port);
    final ProcessList table;
    final ScanRow row;
    switch (found) {
      case _NoListener():
        return const ServerStopEnded();
      case _ListenerUnknown(:final why):
        return ServerStopRefused("Couldn't tell what listens on port $port ($why), so nothing was stopped.");
      case _ListenerFound(table: final t, row: final r):
        table = t;
        row = r;
    }
    final command = row.command;
    if (row.pid == io.pid || command.contains('everyai-backend')) {
      return ServerStopRefused("That's EveryAI's own server.", owner: command);
    }
    // One of ours (the server, or something below it): stopped as the supervisor's child.
    for (final p in table.ancestry(row.pid)) {
      final c = _sup.byPid(p);
      if (c != null) return _settled(c.spec.label, await c.stop());
    }
    if (!listenerMatches(server, command)) {
      return ServerStopRefused(
        "Port $port is held by `${_short(command)}` (pid ${row.pid}), which isn't ${server.label}: EveryAI leaves it "
        'alone.',
        owner: command,
      );
    }
    final mine = table.rows[io.pid]?.uid;
    if (row.uid != null && mine != null && row.uid != mine) {
      return ServerStopRefused(
        server.kind == LocalServerKind.ollama
            ? 'It runs as a system service. Stop it with `sudo systemctl stop ollama`.'
            : "EveryAI isn't allowed to stop it (it runs as another user).",
        owner: command,
      );
    }
    final id = row.identity;
    // Ollama's menu-bar app restarts a server it lost: quit the app instead.
    if (Platform.isMacOS && command.contains('/Ollama.app/')) {
      await _run('/usr/bin/osascript', const ['-e', 'quit app "Ollama"']);
      switch (await _waitGone(id, grace)) {
        case true:
          return ServerStopEnded(Ended([row.pid]));
        case null:
          return ServerStopNotClosed(const ScanFailed('the process table could not be read after Ollama quit'));
        case false:
          break; // Still there: ended below.
      }
    }
    // Checked again right before the signals: the pid must still be the process whose command was matched.
    switch (await _sup.scan()) {
      case ScanFailed(:final why):
        return ServerStopRefused("Couldn't check the listener again before stopping it ($why), so nothing was sent.");
      case Listed(table: final now) when !now.alive(id):
        return ServerStopEnded(Ended([row.pid]));
      case Listed():
        break;
    }
    return _settled('${server.label} (pid ${row.pid})', await _sup.killTree(row.pid, termWait: grace));
  }

  static String _short(String command) => command.length <= 80 ? command : '${command.substring(0, 77)}…';

  /// Whether [id] is gone within [within]: true / false, null when the table can't be read.
  Future<bool?> _waitGone(ProcessIdentity id, Duration within) async {
    final until = DateTime.now().add(within);
    while (true) {
      switch (await _sup.scan()) {
        case ScanFailed():
          return null;
        case Listed(:final table) when !table.alive(id):
          return true;
        case Listed():
          if (DateTime.now().isAfter(until)) return false;
          await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
  }

  /// What listens on loopback [port], read from the OS and the process table.
  Future<_Listener> _listener(int port) async {
    int? pid;
    if (Platform.isWindows) {
      final r = await _run('netstat', const ['-ano', '-p', 'TCP']);
      if (r == null || r.code != 0) return _ListenerUnknown('netstat ${r == null ? "didn't run" : 'failed'}');
      pid = parseNetstatListener(r.out, port);
    } else {
      final lsof = File('/usr/sbin/lsof').existsSync() ? '/usr/sbin/lsof' : 'lsof';
      final r = await _run(lsof, ['-nP', '-iTCP:$port', '-sTCP:LISTEN', '-t']);
      if (r == null) return const _ListenerUnknown("lsof didn't run");
      // lsof exits 1 when nothing matches.
      if (r.code != 0 && r.out.trim().isEmpty) return const _NoListener();
      pid = int.tryParse(r.out.trim().split('\n').first.trim());
    }
    if (pid == null) return const _NoListener();
    switch (await _sup.scan()) {
      case ScanFailed(:final why):
        return _ListenerUnknown('the process table could not be read: $why');
      case Listed(:final table):
        final row = table.rows[pid];
        if (row == null || row.zombie) return const _NoListener();
        return _ListenerFound(table, row);
    }
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
  Future<KillOutcome> stopAllOwned() async {
    final ours = [
      for (final c in _sup.children)
        if (c.state.live && parseLocalServerLabel(c.spec.label) != null) c,
    ];
    final outcome = KillOutcome.merge(await Future.wait([for (final c in ours) c.stop()]));
    if (outcome is! Ended) debugPrint('NOT CLOSED: local servers: $outcome');
    return outcome;
  }
}

sealed class _Listener {
  const _Listener();
}

final class _NoListener extends _Listener {
  const _NoListener();
}

final class _ListenerUnknown extends _Listener {
  const _ListenerUnknown(this.why);
  final String why;
}

final class _ListenerFound extends _Listener {
  const _ListenerFound(this.table, this.row);
  final ProcessList table;
  final ScanRow row;
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
/// pid and a stop reaches it directly. Commands with shell syntax stay as they are (the shell leads the process
/// group, so a stop still ends everything they start).
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

/// [LocalRun] through the process supervisor, [timeout] (10 s) at most: a program still running then is killed
/// with everything it started, and the answer says so (exit -1, "timed out after 10 s (killed)").
Future<({int code, String out})?> runProgram(
  String exe,
  List<String> args, {
  Duration timeout = const Duration(seconds: 10),
  ProcessSupervisor? supervisor,
}) async {
  final RunResult r;
  try {
    r = await (supervisor ?? ProcessSupervisor.instance).runBounded(
      exe,
      args,
      timeout: timeout,
      owner: const ProbeOwner('local-models'),
      stdoutEncoding: utf8,
      maxOutputBytes: 4 << 20,
    );
  } on SupervisorClosed {
    return null; // TODO(supervisor): drop once runBounded answers Refused instead of throwing.
  }
  switch (r) {
    case Finished(:final code, :final stdout):
      return (code: code, out: stdout);
    case StartFailed():
      return null;
    case TimedOut(:final kill) || Cancelled(:final kill):
      final how = kill is Ended ? 'killed' : 'NOT closed: $kill';
      final took = timeout.inSeconds > 0 ? '${timeout.inSeconds} s' : '${timeout.inMilliseconds} ms';
      final said = 'timed out after $took ($how)';
      if (kill is! Ended) debugPrint('NOT CLOSED: $exe ${args.join(' ')}: $said');
      return (code: -1, out: said);
  }
}

bool get runningUnderTest => Platform.environment['FLUTTER_TEST'] == 'true';
