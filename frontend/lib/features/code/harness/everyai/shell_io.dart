// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../../../../core/process/supervisor.dart';
import '../../panes/pty.dart' show ShellPty;
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
    // Interactive + login, so rc files that set PATH run; output before the
    // marker (banners, prompts) is skipped. Bounded: an rc file that waits for input is stopped (verified).
    final res = await ProcessSupervisor.instance.runBounded(
      shell,
      ['-ilc', 'printf "\\n$_marker\\n"; env -0'],
      timeout: const Duration(seconds: 10),
      stdoutEncoding: utf8,
      env: const {'TERM': 'dumb'},
      owner: const ProbeOwner('login-env'),
      label: 'login shell environment',
    );
    switch (res) {
      case Finished(:final stdout):
        final at = stdout.indexOf('$_marker\n');
        if (at >= 0) {
          final env = <String, String>{};
          for (final entry in stdout.substring(at + _marker.length + 1).split('\x00')) {
            final eq = entry.indexOf('=');
            if (eq > 0) env[entry.substring(0, eq)] = entry.substring(eq + 1);
          }
          if (env.containsKey('PATH')) return ShellEnv._(shell, _withCommonDirs(_clean(env)));
        }
        debugPrint('The login shell printed no environment; commands use the app\'s own.');
      case TimedOut() || Cancelled() || StartFailed() || Refused():
        // Timed out, cancelled, didn't start, or the app is quitting: the app's own environment below.
        debugPrint('The login shell environment could not be read ($res); commands use the app\'s own.');
    }
    return ShellEnv._(shell, _withCommonDirs(_clean(Map.of(Platform.environment))));
  }

  static Map<String, String> _withCommonDirs(Map<String, String> env) {
    final windows = Platform.isWindows;
    final key = windows ? env.keys.firstWhere((k) => k.toUpperCase() == 'PATH', orElse: () => 'Path') : 'PATH';
    final home = (windows ? env['USERPROFILE'] : env['HOME']) ?? Platform.environment['HOME'] ?? '';
    return env..[key] = mergePaths(env[key] ?? '', commonDirs(home, env, windows: windows), windows: windows);
  }

  /// Drops what belongs to the capturing shell, not to commands: also the supervisor's tags it carried
  /// (`EVERYAI_APP`, `EVERYAI_OWNER`, `EVERYAI_CHILD`), which every child gets afresh for its own owner.
  static Map<String, String> _clean(Map<String, String> env) => env
    ..removeWhere((k, _) => k.startsWith('EVERYAI_'))
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
  const CommandResult({
    required this.output,
    required this.exitCode,
    this.timedOut = false,
    this.cancelled = false,
    this.stop,
  });
  final String output;

  /// Its exit code; -1 when it was stopped and its own code is unknown, or it isn't closed.
  final int exitCode;
  final bool timedOut;
  final bool cancelled;

  /// What stopping it (at its timeout, or on cancel) came to; null when it ended by itself.
  final KillOutcome? stop;

  /// Whether it (and what it started) is gone: it ended, or its stop was verified.
  bool get closed => stop == null || stop is Ended;
}

/// In the environment of every process a [SessionShell] starts: `<shell instance>/<command id>`, so what a command
/// left running is found by its tag even once it left the command's tree ([SessionShell.killAll]).
const shellEnvVar = 'EVERYAI_SHELL';

/// How a background shell's restart went.
sealed class RestartResult {
  const RestartResult();
}

final class Restarted extends RestartResult {
  const Restarted(this.shell);
  final BackgroundShell shell;
}

/// The old copy didn't close, so no new one was started (two copies would fight over ports and files).
final class RestartRefused extends RestartResult {
  const RestartRefused(this.old, this.stop);
  final BackgroundShell old;
  final KillOutcome stop;
}

final class NoSuchShell extends RestartResult {
  const NoSuchShell();
}

/// Runs a session's commands: each in a fresh login-environment shell, in
/// the directory the previous one ended in (so `cd` carries over), tagged
/// with the session so Stop can find leftovers. Every process goes through the
/// supervisor ([ProcessSupervisor]): its own group, the ledger, a verified stop.
final class SessionShell {
  SessionShell({
    required this.root,
    required this.sessionTag,
    required this.scratchDir,
    this.logDir,
    this.ptySpawner = spawnPty,
    ShellRegistry? registry,
    ProcessSupervisor? supervisor,
    @visibleForTesting this.clock = DateTime.now,
  }) : cwd = root,
       _registry = registry ?? ShellRegistry.instance,
       _sup = supervisor ?? ProcessSupervisor.instance;

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
  final ProcessSupervisor _sup;

  /// Whose processes these are (Stop, delete and quit end them as such).
  ProcessOwner get owner => sessionTag.isEmpty ? const AppOwner() : SessionOwner(sessionTag);

  /// Tells this shell's registry entries apart from a fork's, which shares [sessionTag] and may reuse its ids.
  final String _instance = Random().nextInt(1 << 32).toRadixString(36);

  final _background = <String, BackgroundShell>{};
  int _nextBg = 1;

  // A run's files are named by time and a counter: parallel reads start in
  // the same clock tick (Windows' clock moves every few ms), and other
  // shells may share [scratchDir].
  final DateTime Function() clock;
  int _nextRun = 1;

  /// Foreground commands not yet proven gone (running, or not closed after their stop).
  final _running = <_Proc>{};

  Iterable<BackgroundShell> get background => _background.values;

  /// Processes this session started that are still alive: its commands and
  /// background shells, and everything under them. When the table can't be
  /// read, only the commands themselves (logged): fewer, never a guess.
  Future<Set<int>> processes() async {
    final roots = {
      for (final p in _running) p.pid,
      for (final b in _background.values)
        if (b.running) b.pid,
    };
    switch (await _sup.scan()) {
      case Listed(:final table):
        return {
          for (final r in roots)
            if (table.rows.containsKey(r)) ...[r, ...table.descendants(r)],
        };
      case ScanFailed(:final why):
        debugPrint('SessionShell($sessionTag): the process table could not be read ($why); only the commands.');
        return roots;
    }
  }

  BackgroundShell? backgroundShell(String id) => _background[id];

  String _cwdFile(String id) => '$scratchDir/.cwd-$id';

  /// Writes the wrapper for [command] to a file in [scratchDir] (a long
  /// command doesn't fit on a Windows command line, and Git Bash would parse
  /// its quotes again) and starts the shell on it, through the supervisor: in a
  /// pseudo-terminal when [terminal] and one can be made (stdin left open for
  /// `bash_input`; adopted), else on pipes with stdin from /dev/null.
  Future<(_Proc, File)> _spawn(String id, String command, {bool terminal = false, String? at}) async {
    final cwd = at ?? this.cwd;
    final env = await ShellEnv.load();
    if (env.missing) throw const ShellMissing();
    Directory(scratchDir).createSync(recursive: true);
    final windows = Platform.isWindows;
    final dir = Directory(cwd).existsSync() ? cwd : root;
    final mark = {shellEnvVar: '$_instance/$id'};
    final nested = await NestedDisplays.envFor(sessionTag);
    File script() => File('$scratchDir/.cmd-$id.sh');
    try {
      if (terminal && ptySpawner != null) {
        script().writeAsStringSync(
          wrapScript(command, cwd: cwd, cwdFile: _cwdFile(id), windows: windows, stdinNull: false),
        );
        final path = windows ? script().path.replaceAll('\\', '/') : script().path;
        final pty = await ptySpawner!(
          env.shell,
          [path],
          dir,
          withNestedDisplay({...ptyShellEnv(env.env, sessionTag), ...mark, ..._sup.tagsFor(owner)}, nested),
          ptyRows,
          ptyColumns,
          supervisor: _sup,
          owner: owner,
          label: 'Shell $id',
        );
        if (pty != null) return (_Proc.pty(pty), script());
      }
      script().writeAsStringSync(wrapScript(command, cwd: cwd, cwdFile: _cwdFile(id), windows: windows));
      final process = await _sup.spawn(
        SpawnSpec(
          owner: owner,
          kind: ProcessKind.shell,
          exe: env.shell,
          args: [if (windows) script().path.replaceAll('\\', '/') else script().path],
          // The login environment is whole; the nested display may take variables out (WAYLAND_DISPLAY).
          env: withNestedDisplay({...env.env, sessionEnvVar: sessionTag, ...mark}, nested),
          includeParentEnvironment: false,
          cwd: dir,
          label: 'Shell $id',
        ),
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
    required int pid,
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
      pid: pid,
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

  /// Runs [command] to completion, or until [timeout] or [cancel], when its whole group and tree are stopped
  /// (verified). A command that outlives its stop is not recorded as ended: its entry reads not closed, it stays
  /// in [killAll]'s reach, and the result says so ([CommandResult.stop]).
  Future<CommandResult> run(String command, {required Duration timeout, Future<void>? cancel}) async {
    if ((await ShellEnv.load()).missing) return const CommandResult(output: gitBashMissingMessage, exitCode: 127);
    final n = _nextRun++;
    final id = '${clock().microsecondsSinceEpoch}_$n';
    final (proc, script) = await _spawn(id, command);
    _running.add(proc);
    final (entry, log) = _register('cmd_$n', command, '', background: false, pid: proc.pid);
    entry.live = _WatchedShell(proc);
    _registry
      ..add(entry)
      ..follow(entry, proc.child.state, proc.child.states)
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
    final first = await Future.any<Object>([
      proc.exitCode,
      Future<Object>.delayed(timeout, () => _StopWhy.timedOut),
      if (cancel != null) cancel.then<Object>((_) => _StopWhy.cancelled),
    ]);
    KillOutcome? stop;
    final int code;
    switch (first) {
      case final int c:
        code = c;
        _running.remove(proc);
      default:
        stop = await proc.stop();
        if (stop is Ended) {
          // Proven gone: killAll mustn't reach its pid, which may be reused.
          _running.remove(proc);
          code = await proc.endCode();
        } else {
          // Not closed: it stays listed (the entry says so) and in killAll's reach.
          debugPrint('NOT CLOSED: $command (${proc.pid}): ${killOutcomeText(stop)}');
          code = -1;
        }
    }
    await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
    _delete(script);
    _readCwd(id);
    log?.close();
    _registry.addHints(sessionTag, containerHintsOf(command, out.text));
    return CommandResult(
      output: out.text,
      exitCode: code,
      timedOut: first == _StopWhy.timedOut,
      cancelled: first == _StopWhy.cancelled,
      stop: stop,
    );
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
    final (entry, log) = _register(
      id,
      command,
      description,
      background: true,
      pid: proc.pid,
      restarted: restarted,
      at: at,
    );
    entry.restart = () async {
      // The outcome reaches the agent as a note on the old shell (see [restart]) and the user through its row.
      await restart(id);
    };
    final bg = BackgroundShell._(id, command, description, proc, log, entry, _registry);
    if (restarted) bg._note = const _Restarted();
    _background[id] = bg;
    _registry
      ..add(entry)
      ..follow(entry, proc.child.state, proc.child.states);
    return bg;
  }

  /// Stops background shell [id] (verified) and starts its command again under the same id, in the folder it first
  /// ran in (the user's Restart in the Processes tab). The agent's next read says so. Refused, with the old shell
  /// kept and noted, when the old copy didn't close: two copies would fight over its ports and files.
  ///
  /// Asking again meanwhile joins the restart under way, so a double click starts the command once.
  Future<RestartResult> restart(String id) => _restarting[id] ??= _restart(id).whenComplete(() {
    _restarting.remove(id);
  });

  final _restarting = <String, Future<RestartResult>>{};

  Future<RestartResult> _restart(String id) async {
    final old = _background[id];
    if (old == null) return const NoSuchShell();
    final stop = await old.kill();
    if (stop is! Ended) {
      old._note = _RestartRefused(killOutcomeText(stop));
      _registry.changed(old.entry);
      return RestartRefused(old, stop);
    }
    // In its own folder, without moving the shell's cwd (another command may start meanwhile).
    return Restarted(await _startAs(id, old.command, old.description, restarted: true, at: old.entry.cwd));
  }

  /// Ends every command still running (foreground and background, each verified with its group and tree), then
  /// whatever carries this shell's tag ([shellEnvVar]) but left their trees (a `nohup … &` whose shell ended).
  /// The merged outcome: [Ended] only when everything is proven gone.
  Future<KillOutcome> killAll() async {
    final outcomes = await Future.wait([
      for (final p in [..._running]) p.stop(),
      // Ended ones too: their stop ends what their group or tree left running.
      for (final b in [..._background.values]) b.kill(),
    ]);
    for (final (i, p) in [..._running].indexed) {
      if (outcomes[i] is Ended) _running.remove(p);
    }
    return KillOutcome.merge([...outcomes, await _strays()]);
  }

  /// Ends processes tagged with this shell's [shellEnvVar] (and this app) that are not under a stop already.
  Future<KillOutcome> _strays() async {
    switch (await _sup.scan(env: true)) {
      case ScanFailed() && final failed:
        return failed;
      case Listed(:final table):
        final app = _sup.appTag;
        final tagged = [
          for (final r in table.rows.values)
            if (!r.zombie && (r.tag(shellEnvVar)?.startsWith('$_instance/') ?? false) && r.tag(appEnvVar) == app) r.pid,
        ];
        // Their tops only: a stop ends each one's tree.
        final tops = tagged.where((p) => !tagged.contains(table.rows[p]!.ppid)).toList();
        return KillOutcome.merge(await Future.wait([for (final p in tops) _sup.killTree(p)]));
    }
  }
}

enum _StopWhy { timedOut, cancelled }

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

/// What the agent hasn't been told about a background shell yet.
sealed class _ShellNote {
  const _ShellNote();
}

/// The user restarted it (a new run under the same id).
final class _Restarted extends _ShellNote {
  const _Restarted();
}

/// The user asked for a restart, but the old copy didn't close.
final class _RestartRefused extends _ShellNote {
  const _RestartRefused(this.why);
  final String why;
}

/// A command left running in the background: in a pseudo-terminal when one
/// could be made (so the user can type into it from the Processes tab, and
/// the agent with `bash_input`), else on pipes. Its raw output goes to its
/// log; the agent reads it with colours and redraws taken out. Its state is its
/// registry entry's ([ShellEntry.state]), which follows the supervisor's child.
final class BackgroundShell {
  BackgroundShell._(this.id, this.command, this.description, this._proc, this._log, this.entry, this._registry) {
    entry.live = _LiveBackground(this);
    final decode = const Utf8Decoder(allowMalformed: true).startChunkedConversion(_SinkOf(_add));
    _proc.raw.listen((bytes) {
      final shown = _proc.isPty ? bytes : _crlf(bytes);
      _log?.add(shown);
      entry.emit(shown);
      decode.add(bytes);
    }, onDone: decode.close);
    unawaited(
      _proc.exitCode.then((_) {
        _log?.close();
        _changes.add(null);
      }, onError: (Object e) => debugPrint('Background shell $id: its exit could not be read ($e).')),
    );
    // The registry tells of every state change (stopping, not closed, exited).
    _stateSub = _proc.child.states.listen((_) => _changes.add(null));
  }

  final String id;
  final String command;
  final String description;
  final _Proc _proc;
  final ShellLog? _log;
  final ShellRegistry _registry;
  // ignore: unused_field, cancel_subscriptions
  late final StreamSubscription<ChildState> _stateSub;

  /// Its row in the registry (the Processes tab).
  final ShellEntry entry;
  final _out = _CappedBuffer(2 * 1024 * 1024);
  final _changes = StreamController<void>.broadcast();
  final startedAt = DateTime.now();

  /// When it last printed something.
  DateTime lastOutputAt = DateTime.now();

  _ShellNote? _note;

  /// How much output was read so far (by `bash_output`).
  int readTo = 0;

  int get pid => _proc.pid;

  /// Where its process is (the supervisor's child, through its entry).
  ShellState get state => entry.state;

  /// Whether its process may still be there (running, stopping, or not closed).
  bool get running => entry.running;

  /// Its exit code once it ended (null while it runs or isn't closed, or when the code is unknown).
  int? get exitCode => entry.exitCode;

  /// Whether it runs in a pseudo-terminal, so input reaches it.
  bool get interactive => _proc.isPty;

  /// Everything it printed (capped), as raw text with terminal codes.
  String get output => _out.text;

  /// Fires on new output, state changes and exit.
  Stream<void> get changes => _changes.stream;

  /// What the agent should hear about it before its output, once: a restart by the user, or one refused.
  String? takeNote() {
    final n = _note;
    _note = null;
    return switch (n) {
      null => null,
      _Restarted() => 'The user restarted this shell from the app: the output is from the new run.',
      _RestartRefused(:final why) =>
        'The user asked to restart this shell from the app, but its old copy did not close ($why), so it was not '
            'started again.',
    };
  }

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
    if (state is! ShellRunning || !interactive) return null;
    if ((now ?? DateTime.now()).difference(lastOutputAt) < quiet) return null;
    final text = _out.text;
    final tail = cleanTerminalText(text.substring(text.length > 4000 ? text.length - 4000 : 0));
    final line = tail.split('\n').lastWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    return looksLikePrompt(line) ? line.trim() : null;
  }

  /// Sends [data] to its terminal ([user]: typed by the user, so the agent's next read hears of it).
  /// False when it has no terminal or isn't running.
  bool write(String data, {bool user = false}) {
    if (state is! ShellRunning || !interactive) return false;
    _proc.write(Uint8List.fromList(utf8.encode(data)));
    if (user) {
      entry.noteTyped(data);
      _registry.changed(entry);
    }
    return true;
  }

  /// Ends it, its group and its tree (also once it ended by itself: what it left running), verified.
  Future<KillOutcome> kill() => _proc.stop();
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
  Future<void> stop() => _logged(_b.kill(), 'background shell ${_b.id}');
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
  Future<void> stop() => _logged(_p.stop(), 'command ${_p.pid}');
}

/// Waits for [stop]; one that didn't close is logged loudly (its registry row says not closed too).
Future<void> _logged(Future<KillOutcome> stop, String what) async {
  final out = await stop;
  if (out is! Ended) debugPrint('Stop of $what: ${killOutcomeText(out)}');
}

/// A started command: a supervised process on pipes or a [ShellPty] (adopted); [raw] is all of its output (stdout
/// and stderr interleaved), once, broadcast. [child] is its supervisor record.
final class _Proc {
  _Proc.pipes(SupervisedProcess p) : child = p, _process = p, _pty = null, raw = _merged(p);
  _Proc.pty(ShellPty p) : child = p.child, _process = null, _pty = p, raw = p.output.asBroadcastStream();

  final SupervisedChild child;
  final SupervisedProcess? _process;
  final ShellPty? _pty;
  final Stream<Uint8List> raw;

  bool get isPty => _pty != null;

  /// Known once started (or adopted), which a [_Proc] always is.
  int get pid => child.pid!;
  Future<int> get exitCode => _process?.exitCode ?? _pty!.exitCode;
  void write(Uint8List data) => _pty?.write(data);
  void resize(int rows, int columns) => _pty?.resize(rows, columns);

  /// The supervisor's verified stop of it, its group and its tree.
  Future<KillOutcome> stop() => child.stop();

  /// Its exit code after a stop that ended it: its own (as the supervisor saw it, or its exit future within 2 s),
  /// else -1 (ended, code unknown).
  Future<int> endCode() async {
    if (child.state case ChildExited(:final code?)) return code;
    return exitCode.timeout(const Duration(seconds: 2), onTimeout: () => -1);
  }

  static Stream<Uint8List> _merged(SupervisedProcess p) {
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

/// Ends [pid] and every process below it through the supervisor's verified kill: TERM to its group and tree, up to
/// [termWait] for them to go, KILL for whatever is left, then a check by pid + start time (Windows: `taskkill /T
/// /F`, then a check). For a process the app didn't start through the supervisor; a listed child is stopped as
/// such. Callers act on the outcome: only [Ended] means gone.
Future<KillOutcome> killTree(int pid, {Duration? termWait, ProcessSupervisor? supervisor}) =>
    (supervisor ?? ProcessSupervisor.instance).killTree(pid, termWait: termWait);

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
