// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../panes/pty.dart' show ShellPty;
import '../../live/desktop_helper_io.dart' show windowsParents;
import '../../live/nested_display_io.dart';
import '../../shells/containers.dart' show containerHintsOf;
import '../../shells/pty_spawn_stub.dart' if (dart.library.ffi) '../../shells/pty_spawn_io.dart';
import '../../shells/shell_log_io.dart';
import '../../shells/shell_registry.dart';
import '../../shells/terminal_text.dart';
import '../session_processes.dart' show sessionEnvVar;
import 'git_bash.dart';

export 'git_bash.dart' show gitBashMissingMessage;

/// The user's login shell, and the environment it sets up (PATH from
/// `~/.zshrc` and friends: pyenv, nvm, Homebrew), captured once per app run
/// (until [reload]). Commands then run in that shell with that environment,
/// the way the user's own terminal would run them, not in the app's launchd
/// environment. The usual install directories ([commonDirs]) go after the
/// shell's PATH, so a CLI is found even when the rc files don't add them.
///
/// On Windows the shell is Git Bash ([findGitBash]; empty when it isn't
/// installed, see [missing]) and the environment is the app's own: a Windows
/// app gets the user's full PATH, and Git Bash would hand it back in POSIX
/// form, which the native CLIs started with it can't read.
final class ShellEnv {
  ShellEnv._(this.shell, this.env);

  @visibleForTesting
  ShellEnv.test(this.shell, this.env);

  final String shell;
  final Map<String, String> env;

  /// No shell to run commands in (Windows without Git Bash).
  bool get missing => shell.isEmpty;

  static Future<ShellEnv>? _cached;

  /// Makes [load] return [env] (null: capture again).
  @visibleForTesting
  static void debugUse(ShellEnv? env) => _cached = env == null ? null : Future.value(env);

  static Future<ShellEnv> load() => _cached ??= _capture();

  /// Reads the login shell's environment again (the user installed something).
  static Future<ShellEnv> reload() {
    _cached = null;
    return load();
  }

  static String? get _defaultShell {
    if (Platform.isWindows) return findGitBash(Platform.environment, (f) => File(f).existsSync());
    final s = Platform.environment['SHELL'];
    if (s != null && s.isNotEmpty && File(s).existsSync()) return s;
    return Platform.isMacOS ? '/bin/zsh' : '/bin/bash';
  }

  static const _marker = '__EVERYAI_ENV__';

  static Future<ShellEnv> _capture() async {
    final shell = _defaultShell;
    if (Platform.isWindows || shell == null) {
      return ShellEnv._(shell ?? '', _withCommonDirs(_clean(Map.of(Platform.environment))));
    }
    try {
      // Interactive + login, so rc files that set PATH run; output before the
      // marker (banners, prompts) is skipped.
      final res = await Process.run(
        shell,
        ['-ilc', 'printf "\\n$_marker\\n"; env -0'],
        stdoutEncoding: utf8,
        environment: {'TERM': 'dumb'},
      ).timeout(const Duration(seconds: 10));
      final out = res.stdout as String;
      final at = out.indexOf('$_marker\n');
      if (at >= 0) {
        final env = <String, String>{};
        for (final entry in out.substring(at + _marker.length + 1).split('\x00')) {
          final eq = entry.indexOf('=');
          if (eq > 0) env[entry.substring(0, eq)] = entry.substring(eq + 1);
        }
        if (env.containsKey('PATH')) return ShellEnv._(shell, _withCommonDirs(_clean(env)));
      }
    } on Object {
      // Fall back to the app's own environment below.
    }
    return ShellEnv._(shell, _withCommonDirs(_clean(Map.of(Platform.environment))));
  }

  static Map<String, String> _withCommonDirs(Map<String, String> env) {
    final windows = Platform.isWindows;
    final key = windows ? env.keys.firstWhere((k) => k.toUpperCase() == 'PATH', orElse: () => 'Path') : 'PATH';
    final home = (windows ? env['USERPROFILE'] : env['HOME']) ?? Platform.environment['HOME'] ?? '';
    return env..[key] = mergePaths(env[key] ?? '', commonDirs(home, env, windows: windows), windows: windows);
  }

  /// Drops what belongs to the capturing shell, not to commands.
  static Map<String, String> _clean(Map<String, String> env) => env
    ..remove('SHLVL')
    ..remove('_')
    ..remove('OLDPWD')
    ..remove('PS1')
    ..['TERM'] = 'dumb'
    ..['PAGER'] = 'cat'
    ..['GIT_PAGER'] = 'cat'
    ..['NO_COLOR'] = '1';
}

/// Where CLIs are usually installed, for an app started from the Dock whose
/// login shell doesn't put them on PATH: Homebrew, npm's global prefix
/// (`NPM_CONFIG_PREFIX` or `prefix=` in `~/.npmrc`), nvm's default or newest
/// Node, bun, cargo, volta, deno, Cursor's and the user's own bin. Kept
/// whether they exist yet or not, since the env is kept for the whole run
/// and an installer may make one later (`~/.local/bin`); [exists] only
/// picks nvm's version. [read] and [list] read a file and a directory's
/// entries (null or empty when missing). No process runs.
List<String> commonDirs(
  String home,
  Map<String, String> env, {
  bool windows = false,
  bool Function(String dir)? exists,
  String? Function(String file)? read,
  List<String> Function(String dir)? list,
}) {
  final has = exists ?? (d) => Directory(d).existsSync();
  final readFile =
      read ??
      (f) {
        try {
          return File(f).readAsStringSync();
        } on Object {
          return null;
        }
      };
  final entries =
      list ??
      (d) {
        try {
          return [for (final e in Directory(d).listSync()) e.path.split(Platform.pathSeparator).last];
        } on Object {
          return const [];
        }
      };
  String? nonEmpty(String? v) => v == null || v.trim().isEmpty ? null : v.trim();
  if (windows) {
    return [
      if (nonEmpty(env['APPDATA']) case final a?) '$a\\npm',
      if (nonEmpty(env['LOCALAPPDATA']) case final l?) ...['$l\\Programs\\nodejs', '$l\\Volta\\bin', '$l\\pnpm'],
      if (nonEmpty(env['USERPROFILE']) case final u?) ...['$u\\.local\\bin', '$u\\.bun\\bin', '$u\\scoop\\shims'],
    ];
  }
  String expand(String p) => p.startsWith('~/') ? '$home${p.substring(1)}' : p;
  String? npmPrefix() {
    if (nonEmpty(env['NPM_CONFIG_PREFIX'] ?? env['npm_config_prefix']) case final p?) return expand(p);
    for (final line in (readFile('$home/.npmrc') ?? '').split('\n')) {
      final m = RegExp(r'^\s*prefix\s*=\s*(.+?)\s*$').firstMatch(line);
      if (m != null) return expand(m.group(1)!.replaceAll('"', ''));
    }
    return null;
  }

  String? nvmBin() {
    final nvm = nonEmpty(env['NVM_DIR']) ?? '$home/.nvm';
    final versions = '$nvm/versions/node';
    final alias = nonEmpty(readFile('$nvm/alias/default'));
    if (alias != null && RegExp(r'^v?\d+\.\d+\.\d+$').hasMatch(alias)) {
      final dir = '$versions/${alias.startsWith('v') ? alias : 'v$alias'}/bin';
      if (has(dir)) return dir;
    }
    List<int> parts(String v) => [for (final p in v.replaceFirst('v', '').split('.')) int.tryParse(p) ?? 0];
    int newer(String a, String b) {
      final (x, y) = (parts(a), parts(b));
      for (var i = 0; i < 3 && i < x.length && i < y.length; i++) {
        if (x[i] != y[i]) return x[i].compareTo(y[i]);
      }
      return 0;
    }

    final found = entries(versions).where((v) => RegExp(r'^v\d+\.\d+\.\d+$').hasMatch(v)).toList()..sort(newer);
    return found.isEmpty ? null : '$versions/${found.last}/bin';
  }

  return [
    '/opt/homebrew/bin',
    '/usr/local/bin',
    '$home/.local/bin',
    '$home/.claude/local',
    '$home/.npm-global/bin',
    if (npmPrefix() case final p?) '$p/bin',
    ?nvmBin(),
    '$home/.bun/bin',
    '$home/.cargo/bin',
    '$home/.volta/bin',
    '$home/.deno/bin',
    '$home/.cursor/bin',
    '$home/.opencode/bin',
  ];
}

/// [path] with [extra] directories after it, each kept once (the first
/// time it appears), so the user's own order wins.
String mergePaths(String path, List<String> extra, {bool windows = false}) {
  final sep = windows ? ';' : ':';
  final seen = <String>{};
  return [
    for (final d in [...path.split(sep), ...extra])
      if (d.isNotEmpty && seen.add(windows ? d.toLowerCase() : d)) d,
  ].join(sep);
}

/// What a finished command printed (stdout and stderr interleaved).
final class CommandResult {
  const CommandResult({required this.output, required this.exitCode, this.timedOut = false, this.cancelled = false});
  final String output;
  final int exitCode;
  final bool timedOut;
  final bool cancelled;
}

/// Runs a session's commands: each in a fresh login-environment shell, in
/// the directory the previous one ended in (so `cd` carries over), tagged
/// with the session so Stop can find leftovers.
final class SessionShell {
  SessionShell({
    required this.root,
    required this.sessionTag,
    required this.scratchDir,
    this.logDir,
    this.ptySpawner = spawnPty,
    ShellRegistry? registry,
    @visibleForTesting this.clock = DateTime.now,
  }) : cwd = root,
       _registry = registry ?? ShellRegistry.instance;

  final String root;
  final String sessionTag;

  /// Where wrapper state (the last directory) is kept.
  final String scratchDir;
  String cwd;

  /// Where each command's raw output is kept (`<id>.log`; see [ShellLog]), or null to keep none.
  final String? logDir;

  /// Starts background shells in a pseudo-terminal (null, or when it returns null: pipes).
  final PtySpawner? ptySpawner;
  final ShellRegistry _registry;

  /// Tells this shell's registry entries apart from a fork's, which shares [sessionTag] and may reuse its ids.
  final String _instance = Random().nextInt(1 << 32).toRadixString(36);

  final _background = <String, BackgroundShell>{};
  int _nextBg = 1;

  // A run's files are named by time and a counter: parallel reads start in
  // the same clock tick (Windows' clock moves every few ms), and other
  // shells may share [scratchDir].
  final DateTime Function() clock;
  int _nextRun = 1;
  final _running = <Process>{};

  Iterable<BackgroundShell> get background => _background.values;

  /// Processes this session started that are still alive: its commands and
  /// background shells, and everything under them.
  Future<Set<int>> processes() async {
    final roots = [for (final p in _running) p.pid, for (final b in _background.values) b.pid];
    final out = <int>{};
    for (final r in roots) {
      out
        ..add(r)
        ..addAll(await _descendants(r));
    }
    return out;
  }

  BackgroundShell? backgroundShell(String id) => _background[id];

  String _cwdFile(String id) => '$scratchDir/.cwd-$id';

  /// Writes the wrapper for [command] to a file in [scratchDir] (a long
  /// command doesn't fit on a Windows command line, and Git Bash would parse
  /// its quotes again) and starts the shell on it: in a pseudo-terminal when
  /// [terminal] and one can be made (stdin left open for `bash_input`), else
  /// on pipes with stdin from /dev/null.
  Future<(_Proc, File)> _spawn(String id, String command, {bool terminal = false, String? at}) async {
    final cwd = at ?? this.cwd;
    final env = await ShellEnv.load();
    if (env.missing) throw const ShellMissing();
    Directory(scratchDir).createSync(recursive: true);
    final windows = Platform.isWindows;
    final dir = Directory(cwd).existsSync() ? cwd : root;
    ShellPty? pty;
    File script() => File('$scratchDir/.cmd-$id.sh');
    try {
      if (terminal && ptySpawner != null) {
        script().writeAsStringSync(
          wrapScript(command, cwd: cwd, cwdFile: _cwdFile(id), windows: windows, stdinNull: false),
        );
        final path = windows ? script().path.replaceAll('\\', '/') : script().path;
        pty = await ptySpawner!(
          env.shell,
          [path],
          dir,
          withNestedDisplay(ptyShellEnv(env.env, sessionTag), await NestedDisplays.envFor(sessionTag)),
          ptyRows,
          ptyColumns,
        );
        if (pty != null) return (_Proc.pty(pty), script());
      }
      script().writeAsStringSync(wrapScript(command, cwd: cwd, cwdFile: _cwdFile(id), windows: windows));
      final process = await Process.start(
        env.shell,
        [if (windows) script().path.replaceAll('\\', '/') else script().path],
        environment: withNestedDisplay({
          ...env.env,
          sessionEnvVar: sessionTag,
        }, await NestedDisplays.envFor(sessionTag)),
        workingDirectory: dir,
      );
      return (_Proc.pipes(process), script());
    } on Object {
      _delete(script());
      rethrow;
    }
  }

  /// The size background shells' terminals start at (wide, so the model's view wraps rarely).
  static const ptyRows = 40, ptyColumns = 160;

  /// A registry entry for command [id] and its log file.
  (ShellEntry, ShellLog?) _register(
    String id,
    String command,
    String description, {
    required bool background,
    bool restarted = false,
    String? at,
  }) {
    // A restart gets a log and a registry row of its own.
    final run = restarted ? '-${clock().millisecondsSinceEpoch}' : '';
    final log = logDir == null ? null : ShellLog('$logDir/$id$run.log');
    final entry = ShellEntry(
      key: '$_instance/$id$run',
      id: id,
      session: sessionTag,
      command: command,
      cwd: at ?? cwd,
      origin: ShellOrigin.agent,
      background: background,
      description: description,
      logPath: log?.path,
    );
    // The command line first, dimmed, so a log opened later says what ran.
    final header = utf8.encode('\x1B[2m\$ ${command.trim().replaceAll('\n', '\r\n  ')}\x1B[0m\r\n');
    log?.add(header);
    entry.emit(header);
    return (entry, log);
  }

  void _readCwd(String id) {
    final ended = File(_cwdFile(id));
    if (!ended.existsSync()) return;
    final dir = cwdFromFile(ended.readAsStringSync(), windows: Platform.isWindows);
    if (dir.isNotEmpty && Directory(dir).existsSync()) cwd = dir;
    _delete(ended);
  }

  /// Runs [command] to completion, or until [timeout] (then the whole
  /// process tree is killed) or [cancel] completes.
  Future<CommandResult> run(String command, {required Duration timeout, Future<void>? cancel}) async {
    if ((await ShellEnv.load()).missing) return const CommandResult(output: gitBashMissingMessage, exitCode: 127);
    final n = _nextRun++;
    final id = '${clock().microsecondsSinceEpoch}_$n';
    final (proc, script) = await _spawn(id, command);
    final process = proc.process!;
    _running.add(process);
    final (entry, log) = _register('cmd_$n', command, '', background: false);
    entry
      ..pid = process.pid
      ..live = _WatchedShell(proc);
    _registry
      ..add(entry)
      ..trim(sessionTag);
    final out = _CappedBuffer(4 * 1024 * 1024);
    final done = Completer<void>();
    final decode = const Utf8Decoder(allowMalformed: true).startChunkedConversion(_SinkOf(out.add));
    proc.raw.listen(
      (bytes) {
        final shown = _crlf(bytes);
        log?.add(shown);
        entry.emit(shown);
        decode.add(bytes);
      },
      onDone: () {
        decode.close();
        if (!done.isCompleted) done.complete();
      },
    );
    var timedOut = false, cancelled = false;
    final exit = await Future.any<int?>([
      process.exitCode,
      Future<int?>.delayed(timeout, () {
        timedOut = true;
        return null;
      }),
      if (cancel != null)
        cancel.then((_) {
          cancelled = true;
          return null;
        }),
    ]);
    if (exit == null) await killTree(process.pid);
    final code = exit ?? await process.exitCode.timeout(const Duration(seconds: 3), onTimeout: () => -9);
    // Gone (or past saving): killAll mustn't reach its pid, which may be reused.
    _running.remove(process);
    await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
    _delete(script);
    _readCwd(id);
    log?.close();
    _registry
      ..ended(entry, code)
      ..addHints(sessionTag, containerHintsOf(command, out.text));
    return CommandResult(output: out.text, exitCode: code, timedOut: timedOut, cancelled: cancelled);
  }

  /// Starts [command] in the background; its output collects in the
  /// returned shell until it ends or is killed.
  Future<BackgroundShell> start(String command, {String description = ''}) async {
    return _startAs('bg_${_nextBg++}', command, description);
  }

  Future<BackgroundShell> _startAs(
    String id,
    String command,
    String description, {
    bool restarted = false,
    String? at,
  }) async {
    final (proc, script) = await _spawn(id, command, terminal: true, at: at);
    unawaited(proc.exitCode.then((_) => _delete(script)));
    final (entry, log) = _register(id, command, description, background: true, restarted: restarted, at: at);
    entry.restart = () => restart(id);
    final bg = BackgroundShell._(id, command, description, proc, log, entry, _registry)..restarted = restarted;
    _background[id] = bg;
    _registry.add(entry);
    return bg;
  }

  /// Stops background shell [id] if it runs and starts its command again under the same id, in the folder it first
  /// ran in (the user's Restart in the Processes tab). The agent's next read says so. Null when there is no such
  /// shell.
  ///
  /// A restart takes seconds (the kill waits up to 3 s for the exit); asking again meanwhile joins it, so a double
  /// click starts the command once.
  Future<BackgroundShell?> restart(String id) => _restarting[id] ??= _restart(id).whenComplete(() {
    _restarting.remove(id);
  });

  final _restarting = <String, Future<BackgroundShell?>>{};

  Future<BackgroundShell?> _restart(String id) async {
    final old = _background[id];
    if (old == null) return null;
    await old.kill();
    await old._proc.exitCode.timeout(const Duration(seconds: 3), onTimeout: () => -9);
    // In its own folder, without moving the shell's cwd (another command may start meanwhile).
    return _startAs(id, old.command, old.description, restarted: true, at: old.entry.cwd);
  }

  /// Kills every command still running (foreground and background).
  Future<void> killAll() async {
    for (final p in [..._running]) {
      await killTree(p.pid);
    }
    for (final b in _background.values) {
      await b.kill();
    }
  }
}

/// Thrown when a command is started with no shell to run it in.
final class ShellMissing implements Exception {
  const ShellMissing();
  @override
  String toString() => gitBashMissingMessage;
}

void _delete(File f) {
  try {
    f.deleteSync();
  } on Object {
    // Gone already, or still open on Windows; the scratch folder is the session's own.
  }
}

/// The script run for [command]: in [cwd], and it records the directory it
/// ends in to [cwdFile]. On Windows (Git Bash) paths go in with forward
/// slashes and `pwd -W` writes `C:/…` instead of `/c/…`.
@visibleForTesting
String wrapScript(
  String command, {
  required String cwd,
  required String cwdFile,
  required bool windows,
  bool stdinNull = true,
}) {
  String quote(String s) => "'${(windows ? s.replaceAll('\\', '/') : s).replaceAll("'", r"'\''")}'";
  return 'cd ${quote(cwd)} 2>/dev/null || cd ~\n'
      '{\n$command\n}${stdinNull ? ' < /dev/null' : ''} 2>&1\n'
      '__everyai_status=\$?\n'
      '${windows ? '{ pwd -W 2>/dev/null || pwd -P; }' : 'pwd -P'} > ${quote(cwdFile)} 2>/dev/null\n'
      'exit \$__everyai_status\n';
}

/// The directory a [wrapScript] wrote, in this platform's form.
@visibleForTesting
String cwdFromFile(String text, {required bool windows}) {
  final dir = text.trim();
  return windows ? dir.replaceAll('/', '\\') : dir;
}

/// A command left running in the background: in a pseudo-terminal when one
/// could be made (so the user can type into it from the Processes tab, and
/// the agent with `bash_input`), else on pipes. Its raw output goes to its
/// log; the agent reads it with colours and redraws taken out.
final class BackgroundShell {
  BackgroundShell._(this.id, this.command, this.description, this._proc, this._log, this.entry, this._registry) {
    entry
      ..pid = _proc.pid
      ..live = _LiveBackground(this);
    final decode = const Utf8Decoder(allowMalformed: true).startChunkedConversion(_SinkOf(_add));
    _proc.raw.listen((bytes) {
      final shown = _proc.isPty ? bytes : _crlf(bytes);
      _log?.add(shown);
      entry.emit(shown);
      decode.add(bytes);
    }, onDone: decode.close);
    unawaited(
      _proc.exitCode.then((c) {
        exitCode = c;
        _log?.close();
        _registry.ended(entry, c);
        _changes.add(null);
      }),
    );
  }

  final String id;
  final String command;
  final String description;
  final _Proc _proc;
  final ShellLog? _log;
  final ShellRegistry _registry;

  /// Its row in the registry (the Processes tab).
  final ShellEntry entry;
  final _out = _CappedBuffer(2 * 1024 * 1024);
  final _changes = StreamController<void>.broadcast();
  final startedAt = DateTime.now();

  /// When it last printed something.
  DateTime lastOutputAt = DateTime.now();

  /// The user restarted it (a new run under the same id) and the agent hasn't been told yet.
  bool restarted = false;

  /// Set once it ended.
  int? exitCode;

  /// How much output was read so far (by `bash_output`).
  int readTo = 0;

  int get pid => _proc.pid;
  bool get running => exitCode == null;

  /// Whether it runs in a pseudo-terminal, so input reaches it.
  bool get interactive => _proc.isPty;

  /// Everything it printed (capped), as raw text with terminal codes.
  String get output => _out.text;

  /// Fires on new output and on exit.
  Stream<void> get changes => _changes.stream;

  void _add(String s) {
    _out.add(s);
    lastOutputAt = DateTime.now();
    _changes.add(null);
  }

  /// Output since the last read as plain text (see [cleanTerminalText]), and moves the read mark.
  String takeNew() {
    final all = _out.text;
    final from = readTo.clamp(0, all.length);
    readTo = all.length;
    return cleanTerminalText(all.substring(from));
  }

  /// The prompt it seems to wait at: the last line it printed when that reads like a question and nothing came
  /// for [quiet] (null otherwise).
  String? waitingFor({Duration quiet = const Duration(seconds: 8), DateTime? now}) {
    if (!running || !interactive) return null;
    if ((now ?? DateTime.now()).difference(lastOutputAt) < quiet) return null;
    final text = _out.text;
    final tail = cleanTerminalText(text.substring(text.length > 4000 ? text.length - 4000 : 0));
    final line = tail.split('\n').lastWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    return looksLikePrompt(line) ? line.trim() : null;
  }

  /// Sends [data] to its terminal ([user]: typed by the user, so the agent's next read hears of it).
  /// False when it has no terminal or has ended.
  bool write(String data, {bool user = false}) {
    if (!running || !interactive) return false;
    _proc.write(Uint8List.fromList(utf8.encode(data)));
    if (user) {
      entry.noteTyped(data);
      _registry.changed(entry);
    }
    return true;
  }

  Future<void> kill() async {
    if (!running) return;
    await killTree(_proc.pid);
  }
}

/// A background shell's live end for the registry.
final class _LiveBackground implements LiveShell {
  _LiveBackground(this._b);
  final BackgroundShell _b;

  @override
  bool get interactive => _b.interactive;
  @override
  void write(Uint8List data) => _b.write(utf8.decode(data, allowMalformed: true), user: true);
  @override
  void resize(int rows, int columns) => _b._proc.resize(rows, columns);
  @override
  Future<void> stop() => _b.kill();
}

/// A foreground command's live end: output to follow, no input.
final class _WatchedShell implements LiveShell {
  _WatchedShell(this._p);
  final _Proc _p;

  @override
  bool get interactive => false;
  @override
  void write(Uint8List data) {}
  @override
  void resize(int rows, int columns) {}
  @override
  Future<void> stop() => killTree(_p.pid);
}

/// A started command: a [Process] on pipes or a [ShellPty]; [raw] is all of its output (stdout and stderr
/// interleaved), once, broadcast.
final class _Proc {
  _Proc.pipes(Process p) : process = p, _pty = null, raw = _merged(p);
  _Proc.pty(ShellPty p) : process = null, _pty = p, raw = p.output.asBroadcastStream();

  final Process? process;
  final ShellPty? _pty;
  final Stream<Uint8List> raw;

  bool get isPty => _pty != null;
  int get pid => process?.pid ?? _pty!.pid;
  Future<int> get exitCode => process?.exitCode ?? _pty!.exitCode;
  void write(Uint8List data) => _pty?.write(data);
  void resize(int rows, int columns) => _pty?.resize(rows, columns);

  static Stream<Uint8List> _merged(Process p) {
    final c = StreamController<Uint8List>.broadcast();
    var open = 2;
    void done() {
      if (--open == 0) c.close();
    }

    p.stdout.listen((b) => c.add(Uint8List.fromList(b)), onDone: done);
    p.stderr.listen((b) => c.add(Uint8List.fromList(b)), onDone: done);
    return c.stream;
  }
}

/// Bare LF line ends made CRLF, for output from pipes shown in a terminal.
Uint8List _crlf(List<int> bytes) {
  if (!bytes.contains(0x0A)) return bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final out = BytesBuilder(copy: false);
  var prev = 0;
  for (final b in bytes) {
    if (b == 0x0A && prev != 0x0D) out.addByte(0x0D);
    out.addByte(b);
    prev = b;
  }
  return out.takeBytes();
}

final class _SinkOf implements Sink<String> {
  _SinkOf(this._add);
  final void Function(String) _add;
  @override
  void add(String data) => _add(data);
  @override
  void close() {}
}

/// The environment of a background shell's terminal: the login shell's ([base]) made fit for a terminal (colour
/// on, so the user's view keeps it) but quiet: no pager, no git credential prompts, and the session's tag.
Map<String, String> ptyShellEnv(Map<String, String> base, String sessionTag) => {
  for (final e in base.entries)
    if (e.key != 'NO_COLOR') e.key: e.value,
  'TERM': 'xterm-256color',
  'PAGER': 'cat',
  'GIT_PAGER': 'cat',
  'GIT_TERMINAL_PROMPT': '0',
  sessionEnvVar: sessionTag,
};

/// [env] with the session's own display ([nested], from [NestedDisplays.envFor]) on top; an empty value removes
/// the variable (WAYLAND_DISPLAY, so toolkits don't open on the user's Wayland desktop).
Map<String, String> withNestedDisplay(Map<String, String> env, Map<String, String> nested) {
  if (nested.isEmpty) return env;
  final out = {...env};
  for (final e in nested.entries) {
    if (e.value.isEmpty) {
      out.remove(e.key);
    } else {
      out[e.key] = e.value;
    }
  }
  return out;
}

/// Runs a program and waits for it; [killTree] uses it for `taskkill`.
typedef KillRunner = Future<ProcessResult> Function(String executable, List<String> arguments);

/// Signals [pid] and every process below it: TERM, then KILL for whatever
/// is left a moment later. On Windows ([windows], this host by default)
/// `taskkill /T /F` ends the tree: signals don't exist there, and
/// `Process.killPid` ends one process only. That is what VS Code and
/// tree-kill do; a Job Object would also catch processes whose parent has
/// already exited, but needs FFI handles in every spawner.
///
/// Only for a process that is still running: Windows soon gives a dead
/// process's pid to another one, and `/T` would end that one's tree.
/// [termWait] is how long TERM has before KILL.
Future<void> killTree(
  int pid, {
  bool? windows,
  KillRunner run = Process.run,
  Duration termWait = const Duration(milliseconds: 600),
}) async {
  if (windows ?? Platform.isWindows) {
    // By its full path, so a taskkill.exe in the project can't stand in.
    final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    try {
      final res = await run('$root\\System32\\taskkill.exe', ['/PID', '$pid', '/T', '/F']);
      // 128: no such process, so nothing for the fallback either.
      if (res.exitCode == 0 || res.exitCode == 128) return;
    } on Object {
      // No taskkill: at least the process itself.
    }
    Process.killPid(pid);
    return;
  }
  final pids = await _descendants(pid);
  final all = [pid, ...pids];
  for (final p in all.reversed) {
    Process.killPid(p, ProcessSignal.sigterm);
  }
  await Future<void>.delayed(termWait);
  for (final p in all.reversed) {
    Process.killPid(p, ProcessSignal.sigkill);
  }
}

/// [root]'s descendants now (children first found, then theirs), for a caller that must end them after [root]
/// itself exits (then they belong to init and no walk from [root] finds them).
Future<List<int>> descendantsOf(int root) => _descendants(root);

Future<List<int>> _descendants(int root) async {
  // On Windows only processes() asks (killTree has taskkill there): the desktop helper lists parents.
  if (Platform.isWindows) {
    final parents = await windowsParents();
    final out = <int>[];
    final queue = [root];
    while (queue.isNotEmpty) {
      final p = queue.removeLast();
      for (final e in parents.entries) {
        if (e.value == p && e.key != p && !out.contains(e.key)) {
          out.add(e.key);
          queue.add(e.key);
        }
      }
    }
    return out;
  }
  try {
    final res = await Process.run('ps', ['-A', '-o', 'pid=,ppid=']);
    final children = <int, List<int>>{};
    for (final line in const LineSplitter().convert(res.stdout as String)) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 2) continue;
      final pid = int.tryParse(parts[0]), ppid = int.tryParse(parts[1]);
      if (pid == null || ppid == null) continue;
      children.putIfAbsent(ppid, () => []).add(pid);
    }
    final out = <int>[];
    final queue = [root];
    while (queue.isNotEmpty) {
      for (final c in children[queue.removeLast()] ?? const <int>[]) {
        out.add(c);
        queue.add(c);
      }
    }
    return out;
  } on Object {
    return const [];
  }
}

/// Text that keeps its first half and its newest output once over [cap].
final class _CappedBuffer {
  _CappedBuffer(this.cap);
  final int cap;
  final _head = StringBuffer();
  final _tail = <String>[];
  int _tailLength = 0;
  bool _cut = false;

  void add(String s) {
    if (_head.length < cap ~/ 2) {
      final room = cap ~/ 2 - _head.length;
      if (s.length <= room) {
        _head.write(s);
        return;
      }
      _head.write(s.substring(0, room));
      s = s.substring(room);
    }
    _tail.add(s);
    _tailLength += s.length;
    while (_tailLength > cap ~/ 2 && _tail.length > 1) {
      _tailLength -= _tail.removeAt(0).length;
      _cut = true;
    }
  }

  String get text => _cut ? '$_head\n[… output cut …]\n${_tail.join()}' : '$_head${_tail.join()}';
}
