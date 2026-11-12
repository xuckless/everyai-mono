// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'supervisor.dart';

ProcessSupervisor createSupervisor(SupervisorHooks hooks, {required String? ledgerDir, required bool app}) =>
    _Supervisor(hooks, ledgerDir, app: app);

// ------------------------------------------------------------------ this app

/// This process: its pid, group and start token, read once.
final class _Self {
  _Self._(this.pgid, this.start);
  final int pgid;
  final String start;

  static final _Self it = _read();

  static _Self _read() {
    if (Platform.isWindows) return _Self._(pid, 'unknown');
    try {
      final r = Process.runSync('ps', ['-o', 'pgid=,lstart=', '-p', '$pid'], environment: const {'LC_ALL': 'C'});
      final m = RegExp(r'^\s*(\d+)\s+(.+?)\s*$').firstMatch('${r.stdout}');
      if (r.exitCode == 0 && m != null) return _Self._(int.parse(m.group(1)!), startToken(m.group(2)!));
      debugPrint('Process supervisor: could not read this app\'s start time (ps exit ${r.exitCode}).');
    } on Object catch (e) {
      debugPrint('Process supervisor: could not read this app\'s start time: $e');
    }
    // Unknown: a sweep never takes this run for dead (its start can't be matched), so nothing of it is killed.
    return _Self._(pid, 'unknown');
  }
}

// ------------------------------------------------------------------ raw runs (ps, taskkill; nothing else)

@immutable
sealed class _Raw {
  const _Raw();
}

final class _RawDone extends _Raw {
  const _RawDone(this.code, this.out, this.err);
  final int code;
  final String out;
  final String err;
}

final class _RawFailed extends _Raw {
  const _RawFailed(this.why);
  final String why;
}

/// Runs a system tool that starts nothing of its own (ps, taskkill, PowerShell's process list), bounded: on
/// [timeout] it is killed (one pid; it has no children) and the run fails.
Future<_Raw> _raw(String exe, List<String> args, {Duration timeout = const Duration(seconds: 5)}) async {
  final Process p;
  try {
    p = await Process.start(exe, args, environment: const {'LC_ALL': 'C'});
  } on Object catch (e) {
    return _RawFailed('$exe did not start: $e');
  }
  unawaited(p.stdin.close().catchError((Object _) {}));
  final out = p.stdout.transform(utf8.decoder).join();
  final err = p.stderr.transform(utf8.decoder).join();
  final code = await p.exitCode.timeout(timeout, onTimeout: () => -999999);
  if (code == -999999) {
    final killed = Process.killPid(p.pid, ProcessSignal.sigkill);
    return _RawFailed('$exe took longer than ${timeout.inSeconds} s${killed ? ' (killed)' : ''}');
  }
  return _RawDone(code, await out, await err);
}

const _cimCommand =
    '[Console]::OutputEncoding=[Text.Encoding]::UTF8; '
    'Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId,Name,CommandLine,'
    "@{n='Created';e={if (\$_.CreationDate) { \$_.CreationDate.ToFileTimeUtc() } else { 0 }}} "
    '| ConvertTo-Json -Compress';

/// The real process table.
Future<ProcessScan> _osScan({required bool env}) async {
  if (Platform.isWindows) return _windowsScan();
  final r = await _raw('ps', ['-A', '-ww', '-o', 'pid=,ppid=,pgid=,stat=,lstart=,command=']);
  final String out;
  switch (r) {
    case _RawFailed(:final why):
      return ScanFailed(why);
    case _RawDone(:final code, :final err) when code != 0:
      return ScanFailed('ps exited $code: ${err.trim()}');
    case _RawDone(out: final o):
      out = o;
  }
  var rows = parsePsRows(out);
  if (rows.isEmpty) return const ScanFailed('ps listed no processes');
  if (env) {
    if (Platform.isLinux) {
      rows = [for (final r in rows) r.withEnv(_procEnv(r.pid))];
    } else {
      final withEnv = await _raw('ps', ['-E', '-A', '-ww', '-o', 'pid=,command=']);
      final plain = await _raw('ps', ['-A', '-ww', '-o', 'pid=,command=']);
      if ((withEnv, plain) case (_RawDone(code: 0, out: final e), _RawDone(code: 0, out: final p))) {
        final views = parsePsEnv(e, p);
        rows = [for (final r in rows) r.withEnv(views[r.pid] ?? const EnvHidden())];
      } else {
        return const ScanFailed('ps could not list environments');
      }
    }
  }
  return Listed(ProcessList(rows));
}

EnvView _procEnv(int pid) {
  try {
    return EnvRead(envTagsOf(File('/proc/$pid/environ').readAsStringSync(encoding: latin1)));
  } on FileSystemException {
    return const EnvHidden();
  }
}

Future<ProcessScan> _windowsScan() async {
  final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
  final r = await _raw('$root\\System32\\WindowsPowerShell\\v1.0\\powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    _cimCommand,
  ], timeout: const Duration(seconds: 15));
  switch (r) {
    case _RawFailed(:final why):
      return ScanFailed(why);
    case _RawDone(:final code) when code != 0:
      return ScanFailed('PowerShell exited $code');
    case _RawDone(:final out):
      try {
        final decoded = jsonDecode(out.trim().isEmpty ? '[]' : out);
        final rows = <ScanRow>[
          for (final j in decoded is List ? decoded : [decoded])
            if (j case {'ProcessId': final int pid, 'ParentProcessId': final int ppid})
              ScanRow(
                pid: pid,
                ppid: ppid,
                pgid: pid,
                start: '${j['Created'] ?? 0}',
                command: '${j['CommandLine'] ?? j['Name'] ?? ''}',
              ),
        ];
        return rows.isEmpty ? const ScanFailed('the process list was empty') : Listed(ProcessList(rows));
      } on FormatException catch (e) {
        return ScanFailed('the process list did not parse: $e');
      }
  }
}

bool _osSignal(int pid, ProcessSignal signal) => Process.killPid(pid, signal);

// ------------------------------------------------------------------ launching

/// Keeps a child in a process group of its own on macOS, where there is no `setsid` program: bash with job control
/// puts a background job in a new group (its leader is the program itself); the shell waits and exits with its
/// status (128 + n for a signal), and writes the job's pid (= its group) to `$EVERYAI_JOBFILE`. Its own stderr goes
/// nowhere (job notices); the program's stderr is the real one.
/// Variables bash itself would act on are passed through to the program under other names.
const _macWrapper = r'''
exec 3>&2 2>/dev/null
jf=${EVERYAI_JOBFILE-}
unset EVERYAI_JOBFILE
pre=()
[ -n "${EVERYAI_KEEP_BASH_ENV+x}" ] && pre+=("BASH_ENV=$EVERYAI_KEEP_BASH_ENV")
[ -n "${EVERYAI_KEEP_SHELLOPTS+x}" ] && pre+=("SHELLOPTS=$EVERYAI_KEEP_SHELLOPTS")
[ -n "${EVERYAI_KEEP_BASHOPTS+x}" ] && pre+=("BASHOPTS=$EVERYAI_KEEP_BASHOPTS")
unset EVERYAI_KEEP_BASH_ENV EVERYAI_KEEP_SHELLOPTS EVERYAI_KEEP_BASHOPTS
set -m
if [ ${#pre[@]} -gt 0 ]; then /usr/bin/env "${pre[@]}" "$@" 2>&3 3>&- & else "$@" 2>&3 3>&- & fi
[ -n "$jf" ] && printf '%s\n' "$!" > "$jf"
set +m
exec 3>&-
wait $!
''';

/// How children are put in their own group here.
enum _Grouping {
  /// `setsid` execs the program in a new session (Linux): its pid is the group.
  setsid,

  /// [_macWrapper]: the program runs under a small bash, in a group led by itself.
  bashJob,

  /// No way to (Windows, or neither tool): it shares the app's group, and only its tree is ended.
  none,
}

final _Grouping _grouping = () {
  if (Platform.isWindows) return _Grouping.none;
  if (Platform.isLinux) {
    for (final p in const ['/usr/bin/setsid', '/bin/setsid']) {
      if (File(p).existsSync()) return _Grouping.setsid;
    }
  }
  if (File('/bin/bash').existsSync()) return _Grouping.bashJob;
  debugPrint('Process supervisor: neither setsid nor /bin/bash; children share the app\'s process group.');
  return _Grouping.none;
}();

String get _setsid => File('/usr/bin/setsid').existsSync() ? '/usr/bin/setsid' : '/bin/setsid';

/// Whether [exe] can be found the way the child's exec will look for it (its PATH, its working directory).
bool _findable(String exe, Map<String, String> env, String? cwd) {
  if (Platform.isWindows) return true; // Process.start says so itself there
  bool file(String path) => FileSystemEntity.typeSync(path) == FileSystemEntityType.file;
  if (exe.contains('/')) return file(exe.startsWith('/') ? exe : '${cwd ?? Directory.current.path}/$exe');
  for (final dir in (env['PATH'] ?? '').split(':')) {
    if (file('${dir.isEmpty ? (cwd ?? Directory.current.path) : dir}/$exe')) return true;
  }
  return false;
}

// ------------------------------------------------------------------ records

class _Record implements SupervisedChild {
  _Record(this._sup, this.id, this.spec, {int? pid}) : _pid = pid; // ignore: prefer_initializing_formals

  final _Supervisor _sup;
  @override
  final int id;
  @override
  final SpawnSpec spec;
  int? _pid;

  /// The small shell holding a macOS child in its group (its tree is the child's; it is never signalled).
  ProcessIdentity? _holder;

  @override
  ChildState state = const ChildStarting();
  final _states = StreamController<ChildState>.broadcast(sync: true);
  final _landed = Completer<ProcessIdentity>();
  final _ended = Completer<ExitSeen>();

  /// Done when landing finished: landed, ended first, or given up (the table couldn't be read).
  final _landing = Completer<void>();

  /// The stop under way (a second stop joins it).
  Future<KillOutcome>? _stopping;

  /// When its exit was seen (a group cleanup right after it may go through the group id).
  DateTime? _exitedAt;

  /// The child whose group left this one running (its stop ends this one too).
  int? _origin;

  @override
  Stream<ChildState> get states => _states.stream;
  @override
  Future<ProcessIdentity> get landed => _landed.future;
  @override
  Future<ExitSeen> get ended => _ended.future;
  @override
  int? get pid => _pid;

  ProcessIdentity? get identity => switch (state) {
    ChildRunning(:final id) || ChildTerming(:final id) || ChildKilling(:final id) => id,
    ChildNotClosed(:final survivors) => survivors.first,
    _ => _landed.isCompleted ? _known : null,
  };
  ProcessIdentity? _known;

  /// What the watchdog and the ledger must still end for it.
  List<ProcessIdentity> get liveProcesses => switch (state) {
    ChildRunning(:final id) || ChildTerming(:final id) || ChildKilling(:final id) => [id],
    ChildNotClosed(:final survivors) => survivors,
    _ => const [],
  };

  void apply(ChildChange event) {
    final from = state;
    final next = applyChildEvent(from, event, label: '${spec.label} #$id');
    if (identical(next, from) || next == from) return;
    state = next;
    switch (next) {
      case ChildRunning(:final id):
        _pid = id.pid;
        _known = id;
        if (!_landed.isCompleted) _landed.complete(id);
        if (!_landing.isCompleted) _landing.complete();
        _sup._ledger.add(LedgerRun(id: this.id, identity: id));
      case ChildExited(:final how):
        _exitedAt = DateTime.now();
        _sup._ledger.add(LedgerExit(id: id, code: next.code));
        if (!_ended.isCompleted) _ended.complete(how);
        if (!_landing.isCompleted) _landing.complete();
        if (!_landed.isCompleted) {
          _landed.completeError(StateError('${spec.label} ended before its pid was read'));
          _landed.future.ignore();
        }
      case ChildStartFailed(:final error):
        _sup._ledger.add(LedgerExit(id: id, code: null));
        if (!_landing.isCompleted) _landing.complete();
        if (!_landed.isCompleted) {
          _landed.completeError(StateError(error));
          _landed.future.ignore();
        }
      case ChildNotClosed(:final survivors, :final reason):
        debugPrint('NOT CLOSED: ${spec.label} #$id: $survivors still running ($reason)');
        _sup._ledger.add(LedgerNotClosed(id: id, survivors: survivors, reason: reason));
      case ChildTerming() || ChildKilling():
        _sup._ledger.add(LedgerState(id: id, state: next.name));
      case ChildStarting():
        break;
    }
    _states.add(next);
    _sup._changed(this);
  }

  @override
  Future<KillOutcome> stop() => _sup.stop(this);

  @override
  String toString() => '${spec.label} #$id ($state)';
}

final class _Spawned extends _Record implements SupervisedProcess {
  _Spawned(super.sup, super.id, super.spec);

  late final Process _process;
  late final _Grouping _how;
  final _exitCode = Completer<int>();

  /// The macOS holder's exit code, kept while a check shows the program itself still running (it is used once a
  /// scan sees the program gone).
  int? _exitCodeOnGone;

  /// Its process group, known without a scan: the launched pid under setsid, the job file's pid on macOS.
  int? _groupId;

  /// Where the macOS holder writes the job's pid.
  String? _jobFile;

  /// The job file's pid, once written.
  int? readJobFile() {
    final f = _jobFile;
    if (f == null) return null;
    try {
      final text = File(f).readAsStringSync();
      if (!text.endsWith('\n')) return null;
      return int.tryParse(text.trim());
    } on FileSystemException {
      return null;
    }
  }

  void deleteJobFile() {
    final f = _jobFile;
    if (f == null) return;
    try {
      File(f).deleteSync();
    } on FileSystemException {
      // never written (the program didn't start) or already gone
    }
  }

  @override
  IOSink get stdin => _process.stdin;
  @override
  Stream<List<int>> get stdout => _process.stdout;
  @override
  Stream<List<int>> get stderr => _process.stderr;
  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  bool signal(ProcessSignal signal) {
    final id = identity;
    if (id != null && id.leadsGroup && id.pgid != _Self.it.pgid) return _sup._signal(-id.pgid, signal);
    if (id != null) return _sup._signal(id.pid, signal);
    // Not landed yet: on Linux the launched pid is the program (and its group).
    return _how == _Grouping.setsid ? _sup._signal(-_process.pid, signal) : false;
  }
}

// ------------------------------------------------------------------ the supervisor

final class _Supervisor extends ProcessSupervisor {
  _Supervisor(this.hooks, String? dir, {required this.app}) : _dir = dir;

  final SupervisorHooks hooks;
  final bool app;
  String? _dir;
  var _ids = 0;
  final _list = <int, _Record>{};
  late final _ledger = _LedgerWriter(this);
  Future<String>? _ready;
  final _sweep = ValueNotifier<SweepReport?>(null);
  Future<SweepReport>? _sweeping;
  final _watched = <_Record>{};
  Timer? _poller;
  final _lingerQueue = <_Spawned>[];
  Timer? _lingerTimer;

  StopTimings get t => hooks.timings;

  Future<ProcessScan> _scan({bool env = false}) => (hooks.scan ?? _osScan)(env: env);
  bool _signal(int pid, ProcessSignal s) => (hooks.signal ?? _osSignal)(pid, s);

  @override
  set ledgerDirectory(String path) {
    if (_ready != null && _dir != path) debugPrint('Process supervisor: the ledger folder was set after first use.');
    _dir = path;
  }

  @override
  Future<String> get ledgerDirectory => _ready ??= _start();

  @override
  String get appTag => '$pid:${_Self.it.start}';

  Future<String> _start() async {
    var dir = _dir;
    if (dir == null) {
      if (!app || Platform.environment['FLUTTER_TEST'] == 'true') {
        dir = '${Directory.systemTemp.path}/everyai-processes${app ? '-test' : '-$pid-${identityHashCode(this)}'}';
      } else {
        try {
          dir = '${(await getApplicationSupportDirectory()).path}/processes';
        } on Object catch (e) {
          dir = '${Directory.systemTemp.path}/everyai-processes';
          debugPrint('Process supervisor: no app support folder ($e); the ledger is in $dir.');
        }
      }
    }
    _dir = dir;
    try {
      Directory(dir).createSync(recursive: true);
    } on FileSystemException catch (e) {
      debugPrint('Process supervisor: the ledger folder $dir could not be made: $e');
    }
    _ledger.open(dir);
    if (hooks.watchdog && !Platform.isWindows) _startWatchdog(dir);
    // Once this start has returned (the sweep reads the folder through [ledgerDirectory] too).
    if (app) scheduleMicrotask(() => unawaited(sweepPreviousRuns()));
    return dir;
  }

  void _changed(_Record r) {
    if (!r.state.live) {
      _list.remove(r.id);
      _watched.remove(r);
    } else {
      _list[r.id] = r; // an ended child whose group left processes is listed again (not closed)
    }
    _ledger.writeWatchList();
  }

  // ---------------------------------------------------------------- spawn

  @override
  Future<SupervisedProcess> spawn(SpawnSpec spec) async {
    final r = _Spawned(this, ++_ids, spec);
    _list[r.id] = r;
    try {
      await ledgerDirectory;
      _ledger.add(LedgerSpawn(id: r.id, exe: spec.exe, owner: spec.owner.key, kind: spec.kind.name, label: spec.label));
      final env = <String, String>{
        if (spec.includeParentEnvironment) ...Platform.environment,
        ...spec.env,
        appEnvVar: appTag,
        ownerEnvVar: spec.owner.key,
        if (spec.owner case SessionOwner(:final id) when !spec.env.containsKey(sessionTagEnvVar)) sessionTagEnvVar: id,
      };
      if (!_findable(spec.exe, env, spec.cwd)) {
        throw ProcessException(spec.exe, spec.args, 'No such file or directory', 2);
      }
      r._how = _grouping;
      final (exe, args) = switch (_grouping) {
        _Grouping.setsid => (_setsid, [spec.exe, ...spec.args]),
        _Grouping.bashJob => ('/bin/bash', ['-c', _macWrapper, 'everyai-child', spec.exe, ...spec.args]),
        _Grouping.none => (spec.exe, spec.args),
      };
      if (_grouping == _Grouping.bashJob) {
        for (final k in const ['BASH_ENV', 'SHELLOPTS', 'BASHOPTS']) {
          if (env.remove(k) case final v?) env['EVERYAI_KEEP_$k'] = v;
        }
        final jobs = Directory('${await ledgerDirectory}/jobs')..createSync(recursive: true);
        env['EVERYAI_JOBFILE'] = r._jobFile = '${jobs.path}/$pid-${r.id}';
      }
      r._process = await Process.start(
        exe,
        args,
        environment: env,
        includeParentEnvironment: false,
        workingDirectory: spec.cwd,
      );
    } on Object catch (e) {
      r.apply(ChildFailedToStart('$e'));
      _list.remove(r.id);
      rethrow;
    }
    if (r._how != _Grouping.bashJob) r._pid = r._process.pid;
    if (r._how == _Grouping.setsid) r._groupId = r._process.pid;
    unawaited(r._process.exitCode.then((code) => _launchExited(r, code)));
    unawaited(_land(r));
    return r;
  }

  Future<void> _land(_Spawned r) async {
    final launched = r._process.pid;
    if (r._how == _Grouping.bashJob) await _awaitJob(r);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    var failures = 0;
    while (r.state is ChildStarting) {
      final scan = await _scan();
      if (r.state is! ChildStarting) return;
      switch (scan) {
        case ScanFailed(:final why):
          if (++failures >= 3) {
            debugPrint('Process supervisor: ${r.spec.label} #${r.id} started, but its pid can\'t be checked: $why');
            if (!r._landing.isCompleted) r._landing.complete();
            return;
          }
        case Listed(:final table):
          final ScanRow? row;
          if (r._how == _Grouping.bashJob) {
            r._holder ??= table.rows[launched]?.identity;
            row = switch (r._groupId) {
              final job? => table.rows[job],
              null => null,
            };
          } else {
            row = table.rows[launched];
          }
          if (row != null && !row.zombie) {
            r.apply(ChildLanded(row.identity, DateTime.now()));
            return;
          }
          // Gone already (its exit lands next).
          if (r._how != _Grouping.bashJob || r._groupId != null || DateTime.now().isAfter(deadline)) {
            if (!r._landing.isCompleted) r._landing.complete();
            return;
          }
      }
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
  }

  /// macOS: waits (briefly) for the holder to name its job, so the scan looks for that pid.
  Future<void> _awaitJob(_Spawned r) async {
    final until = DateTime.now().add(const Duration(seconds: 3));
    while (r._groupId == null && r.state is ChildStarting && DateTime.now().isBefore(until)) {
      r._groupId = r.readJobFile();
      if (r._groupId == null) await Future<void>.delayed(const Duration(milliseconds: 3));
    }
  }

  /// The launched process ended: the program itself (Linux, Windows), or the macOS holder once its job ended.
  Future<void> _launchExited(_Spawned r, int code) async {
    final id = r.identity;
    // The holder's `wait` relays the program's own status (0-255) once the program ended; a negative code is the
    // holder itself killed by a signal (by someone else: the supervisor never signals it), so the program is checked.
    if (r._how == _Grouping.bashJob && id != null && code < 0) {
      final scan = await _scan();
      if (scan case Listed(:final table) when table.alive(id)) {
        debugPrint('Process supervisor: ${r.spec.label} #${r.id}: its holder exited ($code) but it still runs.');
        _watch(r);
        r._exitCodeOnGone = code;
        return;
      }
    }
    r._groupId ??= r.readJobFile();
    r.deleteJobFile();
    if (!r._exitCode.isCompleted) r._exitCode.complete(code);
    r.apply(ChildExitSeen(ExitCode(code)));
    if (r.state is ChildExited && _groupOf(r) != null) _queueLinger(r);
  }

  // ---------------------------------------------------------------- what a child's group leaves behind

  /// The group a spawned child leads, when known (from its landing, or without one).
  int? _groupOf(_Record r) {
    final g = switch (r._known) {
      final id? when id.leadsGroup => id.pgid,
      _ => r is _Spawned ? r._groupId : null,
    };
    return g == null || g <= 1 || g == _Self.it.pgid ? null : g;
  }

  void _queueLinger(_Spawned r) {
    _lingerQueue.add(r);
    _lingerTimer ??= Timer(const Duration(milliseconds: 200), _lingerCheck);
  }

  Future<void> _lingerCheck() async {
    _lingerTimer = null;
    final batch = [..._lingerQueue];
    _lingerQueue.clear();
    final scan = await _scan();
    if (scan is! Listed) {
      debugPrint('Process supervisor: could not check what ${batch.length} ended children left running.');
      return;
    }
    for (final r in batch) {
      final g = _groupOf(r)!;
      for (final p in scan.table.group(g)) {
        final row = scan.table.rows[p]!;
        if (row.zombie || _list.values.any((x) => x.pid == p)) continue;
        final left = adoptKnown(
          row.identity,
          SpawnSpec(owner: r.spec.owner, kind: r.spec.kind, exe: row.command, label: '${r.spec.label} (left running)'),
        ).._origin = r.id;
        debugPrint('Process supervisor: ${r.spec.label} #${r.id} ended and left $left running; it is listed now.');
      }
    }
  }

  // ---------------------------------------------------------------- adopt

  @override
  SupervisedChild adopt(int pid, SpawnSpec spec, {Future<int>? exitCode}) {
    final r = _Record(this, ++_ids, spec, pid: pid);
    _list[r.id] = r;
    unawaited(ledgerDirectory);
    _ledger.add(LedgerSpawn(id: r.id, exe: spec.exe, owner: spec.owner.key, kind: spec.kind.name, label: spec.label));
    if (exitCode != null) {
      unawaited(
        exitCode.then(
          (code) => r.apply(ChildExitSeen(ExitCode(code))),
          onError: (Object e) {
            debugPrint('Process supervisor: ${spec.label}: its exit future failed ($e); watching the table instead.');
            _watch(r);
          },
        ),
      );
    }
    unawaited(_landAdopted(r, waitsOnExit: exitCode != null));
    _ledger.writeWatchList();
    return r;
  }

  /// Lists a process already known by pid + start time (left behind by a child's group, or by a dead run).
  _Record adoptKnown(ProcessIdentity id, SpawnSpec spec) {
    final r = _Record(this, ++_ids, spec, pid: id.pid);
    _list[r.id] = r;
    _ledger.add(LedgerSpawn(id: r.id, exe: spec.exe, owner: spec.owner.key, kind: spec.kind.name, label: spec.label));
    r.apply(ChildLanded(id, DateTime.now()));
    _watch(r);
    return r;
  }

  Future<void> _landAdopted(_Record r, {required bool waitsOnExit}) async {
    for (var tries = 0; tries < 3 && r.state is ChildStarting; tries++) {
      final scan = await _scan();
      if (r.state is! ChildStarting) return;
      switch (scan) {
        case ScanFailed():
          await Future<void>.delayed(const Duration(milliseconds: 100));
        case Listed(:final table):
          final row = table.rows[r.pid!];
          if (row != null && !row.zombie) {
            r.apply(ChildLanded(row.identity, DateTime.now()));
            if (!waitsOnExit) _watch(r);
          } else if (!waitsOnExit) {
            r.apply(const ChildExitSeen(SeenGone()));
          } else if (!r._landing.isCompleted) {
            r._landing.complete(); // its exit future says the rest
          }
          return;
      }
    }
    if (r.state is ChildStarting) {
      debugPrint('Process supervisor: ${r.spec.label} (${r.pid}) was adopted, but its start time can\'t be read.');
      if (!r._landing.isCompleted) r._landing.complete();
    }
  }

  // ---------------------------------------------------------------- watching ends the app can't wait on

  void _watch(_Record r) {
    _watched.add(r);
    _poller ??= Timer.periodic(const Duration(seconds: 1), (_) => _pollWatched());
  }

  var _polling = false;

  Future<void> _pollWatched() async {
    if (_polling) return;
    _watched.removeWhere((r) => !r.state.live);
    if (_watched.isEmpty) {
      _poller?.cancel();
      _poller = null;
      return;
    }
    _polling = true;
    try {
      final scan = await _scan();
      if (scan is! Listed) return;
      for (final r in [..._watched]) {
        final id = r.identity;
        if (id == null || r._stopping != null) continue;
        if (r.state is ChildNotClosed) {
          final left = (r.state as ChildNotClosed).survivors.where(scan.table.alive).toList();
          if (left.isEmpty) r.apply(_goneEvent(r));
        } else if (!scan.table.alive(id)) {
          r.apply(_goneEvent(r));
        }
      }
    } finally {
      _polling = false;
    }
  }

  ChildChange _goneEvent(_Record r) {
    if (r is _Spawned && r._exitCodeOnGone != null) {
      final code = r._exitCodeOnGone!;
      if (!r._exitCode.isCompleted) r._exitCode.complete(code);
      return ChildExitSeen(ExitCode(code));
    }
    return const ChildExitSeen(SeenGone());
  }

  // ---------------------------------------------------------------- stopping

  @override
  Future<KillOutcome> stop(SupervisedChild child) {
    if (child is! _Record || !identical(child._sup, this)) {
      return Future.value(child.state.live ? const ScanFailed('not a child of this supervisor') : const Ended([]));
    }
    final r = child;
    if (r.state is ChildStartFailed) return Future.value(const Ended([]));
    final running = r._stopping;
    if (running != null) return running;
    final f = _stopRecord(r);
    r._stopping = f;
    unawaited(
      f.whenComplete(() {
        r._stopping = null;
      }),
    );
    return f;
  }

  Future<KillOutcome> _stopRecord(_Record r) async {
    if (r.state is ChildStarting) await r._landing.future;
    switch (r.state) {
      case ChildStartFailed():
        return const Ended([]);
      case ChildExited():
        // The program is gone; what its group left running is ended with it: right after the exit through the
        // group (no other group can have its id yet), and always through what was listed as left running.
        final g = _groupOf(r);
        final recent = switch (r._exitedAt) {
          final at? => DateTime.now().difference(at) < const Duration(seconds: 5),
          null => false,
        };
        final left = [
          for (final x in _list.values)
            if (x._origin == r.id) x,
        ];
        final outcomes = await Future.wait([for (final x in left) stop(x)]);
        if (g == null || !recent) return KillOutcome.merge(outcomes);
        final leader = r._known ?? ProcessIdentity(pid: g, pgid: g, start: 'ended');
        final res = await _end(roots: const [], treeOnly: const [], leaders: [leader], leaderless: true, rec: r);
        return KillOutcome.merge([...outcomes, await _settle(r, res)]);
      case ChildStarting():
        // Started, but its pid + start time couldn't be read: end what is known of it, and say it can't be checked.
        final p = r is _Spawned ? r._process.pid : r.pid;
        if (p != null && r is _Spawned && r._how == _Grouping.setsid) _signal(-p, ProcessSignal.sigkill);
        if (p != null && !(r is _Spawned && r._how == _Grouping.bashJob)) _signal(p, ProcessSignal.sigkill);
        return const ScanFailed('its pid and start time could not be read, so its end could not be checked');
      default:
        break;
    }
    final roots = [...r.liveProcesses];
    final result = await _end(
      roots: roots,
      treeOnly: [?r._holder],
      leaders: [
        for (final p in roots)
          if (p.leadsGroup) p,
      ],
      // A child followed since it started: its group is its own even once its leader has gone.
      leaderless: true,
      rec: r,
    );
    return _settle(r, result);
  }

  /// Turns what [_end] found into the child's state and the outcome.
  Future<KillOutcome> _settle(_Record r, _EndResult res) async {
    if (res.failure case final why?) {
      // Not exited: only its own exit future or a check could say so.
      if (r.identity case final id? when r.state.live) r.apply(ChildSurvivors([id], 'could not check its end: $why'));
      return ScanFailed(why);
    }
    final survivors = res.survivors.toList();
    if (survivors.isEmpty) {
      if (r.state.live) {
        // Checked gone; for a child the app waits on, its own exit (and code) follows at once.
        if (r is _Spawned) {
          await r._ended.future.timeout(const Duration(seconds: 1), onTimeout: () => const SeenGone());
        }
        if (r.state.live) r.apply(_goneEvent(r));
      }
      return Ended(res.ended);
    }
    const reason = 'still running after SIGKILL';
    r.apply(ChildSurvivors(survivors, reason));
    _watch(r);
    return Survived([for (final s in survivors) s.pid], reason, ended: res.ended);
  }

  @override
  Future<KillOutcome> stopOwner(ProcessOwner owner, {bool tagged = true, bool descendants = true}) async {
    final mine = [
      for (final r in _list.values)
        if (r.spec.owner == owner) r,
    ];
    final outcomes = await Future.wait([for (final r in mine) stop(r)]);
    if (!tagged) return KillOutcome.merge(outcomes);
    final tag = appTag;
    final res = await _end(
      roots: const [],
      treeOnly: const [],
      leaders: const [],
      tagged: (row) => row.tag(ownerEnvVar) == owner.key && row.tag(appEnvVar) == tag,
      descendants: descendants,
      env: true,
    );
    return KillOutcome.merge([...outcomes, res.outcome]);
  }

  @override
  Future<KillOutcome> killTree(int pid, {Duration? termWait}) async {
    if (byPid(pid) case final r?) return stop(r);
    if (Platform.isWindows) return _windowsKillTree(pid);
    final scan = await _scan();
    final timings = StopTimings(termGrace: termWait ?? t.termGrace, killWait: t.killWait, poll: t.poll);
    switch (scan) {
      case ScanFailed(:final why):
        // Blind, as before: TERM, the grace, KILL; but said to be unchecked.
        _signal(pid, ProcessSignal.sigterm);
        await Future<void>.delayed(timings.termGrace);
        _signal(pid, ProcessSignal.sigkill);
        return ScanFailed(why);
      case Listed(:final table):
        final row = table.rows[pid];
        if (row == null || row.zombie) return const Ended([]);
        final id = row.identity;
        return (await _end(
          roots: [id],
          treeOnly: const [],
          leaders: [if (id.leadsGroup) id],
          timings: timings,
          first: scan,
        )).outcome;
    }
  }

  Future<KillOutcome> _windowsKillTree(int pid) async {
    final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final r = await _raw('$root\\System32\\taskkill.exe', ['/PID', '$pid', '/T', '/F']);
    if (r case _RawDone(:final code) when code != 0 && code != 128) _signal(pid, ProcessSignal.sigkill);
    final scan = await _scan();
    return switch (scan) {
      ScanFailed() => scan,
      Listed(:final table) when table.rows.containsKey(pid) => Survived([pid], 'still running after taskkill /F'),
      Listed() => Ended([pid]),
    };
  }

  /// The verified kill: SIGTERM to the groups of [leaders], [roots] and what the table shows for them (their trees,
  /// what [tagged] matches, the trees under [treeOnly] without those themselves); a wait that ends once all are
  /// gone; SIGKILL to what is left (and what appeared meanwhile); then a check by pid + start time.
  ///
  /// A group is signalled only once it is known to be ours: its leader is in the table with its start time (and
  /// then for the rest of this kill), or, with [leaderless], its leader is gone (a child followed since it
  /// started). A leader's pid with another start time means the group id is someone else's: never signalled.
  Future<_EndResult> _end({
    required List<ProcessIdentity> roots,
    required List<ProcessIdentity> treeOnly,
    required List<ProcessIdentity> leaders,
    bool leaderless = false,
    bool Function(ScanRow row)? tagged,
    bool descendants = true,
    bool env = false,
    _Record? rec,
    StopTimings? timings,
    ProcessScan? first,
  }) async {
    final tm = timings ?? t;
    final self = _Self.it;
    final targets = <int, ProcessIdentity>{};
    final candidates = [
      for (final l in leaders)
        if (l.pgid > 1 && l.pgid != self.pgid && l.leadsGroup) l,
    ];
    final groups = <int>{};
    String? lastFailure;

    void verifyGroups(ProcessList table) {
      for (final l in [...candidates]) {
        final row = table.rows[l.pid];
        final ok = switch (row) {
          null => leaderless,
          ScanRow(zombie: true) => leaderless,
          final r => r.start == l.start && r.pgid == l.pgid,
        };
        if (ok) groups.add(l.pgid);
        candidates.remove(l); // decided once: ours for this kill, or never
      }
    }

    void collect(ProcessList table) {
      verifyGroups(table);
      final spare = table.ancestry(pid)..add(1);
      void add(int p) {
        final row = table.rows[p];
        if (row == null || row.zombie || spare.contains(p) || p <= 1) return;
        targets[p] ??= row.identity;
      }

      for (final r in roots) {
        if (table.alive(r)) {
          targets[r.pid] ??= r;
          if (descendants) table.descendants(r.pid).forEach(add);
        }
      }
      for (final h in treeOnly) {
        if (table.alive(h)) table.descendants(h.pid).forEach(add);
      }
      for (final g in groups) {
        table.group(g).forEach(add);
      }
      if (tagged != null) {
        for (final row in table.rows.values) {
          if (!tagged(row)) continue;
          add(row.pid);
          if (descendants) table.descendants(row.pid).forEach(add);
        }
      }
      // Whatever a target started meanwhile.
      if (descendants) {
        for (final p in [...targets.keys]) {
          if (table.alive(targets[p]!)) table.descendants(p).forEach(add);
        }
      }
    }

    // Who is still running, by pid + start time; null when the table can't be read.
    Future<Set<ProcessIdentity>?> left() async {
      final s = await _scan(env: env);
      switch (s) {
        case ScanFailed(:final why):
          lastFailure = why;
          return null;
        case Listed(:final table):
          lastFailure = null;
          collect(table);
          return {
            for (final p in targets.values)
              if (table.alive(p)) p,
          };
      }
    }

    void send(ProcessSignal sig) {
      if (Platform.isWindows) return; // taskkill below
      for (final g in groups) {
        _signal(-g, sig);
      }
      for (final p in targets.values) {
        _signal(p.pid, sig);
      }
    }

    Future<Set<ProcessIdentity>?> waitGone(Duration budget) async {
      final until = DateTime.now().add(budget);
      Set<ProcessIdentity>? now;
      while (true) {
        now = await left();
        final groupsEmpty = now != null && groups.every((g) => now!.every((p) => p.pgid != g));
        if (now != null && now.isEmpty && groupsEmpty) return now;
        if (DateTime.now().isAfter(until)) return now;
        await Future<void>.delayed(tm.poll);
      }
    }

    // The first look.
    switch (first ?? await _scan(env: env)) {
      case ScanFailed(:final why):
        lastFailure = why;
        for (final r in roots) {
          targets[r.pid] = r; // blind: the roots as known
        }
        if (leaderless) groups.addAll([for (final l in candidates) l.pgid]);
      case Listed(:final table):
        collect(table);
    }
    if (Platform.isWindows) {
      for (final p in targets.values) {
        final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
        await _raw('$root\\System32\\taskkill.exe', ['/PID', '${p.pid}', '/T', '/F']);
      }
      final now = await waitGone(tm.killWait);
      return _EndResult(targets.values.toSet(), now ?? targets.values.toSet(), now == null ? lastFailure : null);
    }
    if (targets.isEmpty && groups.isEmpty && lastFailure == null) return const _EndResult({}, {}, null);
    rec?.apply(ChildTermSent(DateTime.now()));
    send(ProcessSignal.sigterm);
    var now = await waitGone(tm.termGrace);
    final groupsLeft = now == null || groups.any((g) => now!.any((p) => p.pgid == g));
    if (now == null || now.isNotEmpty || groupsLeft) {
      rec?.apply(ChildKillSent(DateTime.now()));
      send(ProcessSignal.sigkill);
      now = await waitGone(tm.killWait);
    }
    if (now == null) return _EndResult(targets.values.toSet(), targets.values.toSet(), lastFailure);
    return _EndResult(targets.values.toSet(), now, null);
  }

  // ---------------------------------------------------------------- bounded runs

  @override
  Future<RunResult> runBounded(
    String exe,
    List<String> args, {
    required Duration timeout,
    Future<void>? cancel,
    ProcessOwner owner = const AppOwner(),
    ProcessKind kind = ProcessKind.oneShot,
    Map<String, String> env = const {},
    bool includeParentEnvironment = true,
    String? cwd,
    String? stdin,
    Encoding encoding = systemEncoding,
    String? label,
  }) async {
    final SupervisedProcess p;
    try {
      p = await spawn(
        SpawnSpec(
          owner: owner,
          kind: kind,
          exe: exe,
          args: args,
          env: env,
          includeParentEnvironment: includeParentEnvironment,
          cwd: cwd,
          label: label ?? '$exe ${args.join(' ')}'.trim(),
        ),
      );
    } on Object catch (e) {
      return StartFailed('$e');
    }
    final out = <int>[], err = <int>[];
    final outDone = p.stdout.forEach(out.addAll);
    final errDone = p.stderr.forEach(err.addAll);
    if (stdin != null) p.stdin.write(stdin);
    unawaited(p.stdin.close().catchError((Object _) {}));
    String text(List<int> b) => encoding.decode(b);

    final stopReason = Completer<bool>(); // true: timed out, false: cancelled
    final timer = Timer(timeout, () {
      if (!stopReason.isCompleted) stopReason.complete(true);
    });
    if (cancel != null) {
      unawaited(
        cancel.then((_) {
          if (!stopReason.isCompleted) stopReason.complete(false);
        }, onError: (Object _) {}),
      );
    }
    final finished = Future.wait([p.exitCode, outDone, errDone]).then((r) => r.first as int);
    final first = await Future.any<Object>([finished, stopReason.future]);
    timer.cancel();
    if (first is int) return Finished(first, text(out), text(err));
    final kill = await p.stop();
    // What it wrote up to the stop (its pipes close with it).
    await Future.wait([outDone, errDone]).timeout(const Duration(milliseconds: 500), onTimeout: () => const []);
    return first == true
        ? TimedOut(kill, stdout: text(out), stderr: text(err))
        : Cancelled(kill, stdout: text(out), stderr: text(err));
  }

  @override
  Future<ProcessScan> scan({bool env = false}) => _scan(env: env);

  // ---------------------------------------------------------------- the launch sweep

  @override
  ValueListenable<SweepReport?> get lastSweep => _sweep;

  @override
  Future<SweepReport> sweepPreviousRuns() => _sweeping ??= _sweepNow().then((r) => _sweep.value = r);

  Future<SweepReport> _sweepNow() async {
    final dir = await ledgerDirectory;
    final own = _ledger.path;
    final files = <File>[];
    try {
      for (final e in Directory(dir).listSync()) {
        final name = e.uri.pathSegments.last;
        if (e is File && name.startsWith('ledger-') && name.endsWith('.jsonl') && e.path != own) files.add(e);
      }
    } on FileSystemException catch (e) {
      return SweepReport(failure: 'the ledger folder could not be read: $e');
    }
    final scan = await _scan(env: true);
    final ProcessList table;
    switch (scan) {
      case ScanFailed(:final why):
        return SweepReport(failure: 'the process table could not be read: $why');
      case Listed(table: final tb):
        table = tb;
    }
    final targets = <int, ({ProcessIdentity id, String label, String owner})>{};
    final leftAlone = <SweptProcess>[];
    final swept = <File>[];
    for (final f in files) {
      final List<String> lines;
      try {
        lines = f.readAsLinesSync();
      } on FileSystemException {
        continue;
      }
      final fold = LedgerFold.of(lines);
      if (fold.app case final a? when a.start != 'unknown' && table.aliveAt(a.pid, a.start)) continue; // still running
      if (fold.app case final a? when a.start == 'unknown' && table.rows.containsKey(a.pid)) continue; // can't tell
      swept.add(f);
      for (final c in fold.live) {
        for (final p in c.processes) {
          if (table.aliveAt(p.pid, p.start)) {
            targets[p.pid] = (id: table.rows[p.pid]!.identity, label: c.label, owner: c.owner);
          } else if (table.rows[p.pid] case final now? when !now.zombie) {
            leftAlone.add((pid: p.pid, label: c.label, why: 'pid now belongs to another process (${now.command})'));
          }
        }
      }
    }
    final mine = appTag;
    for (final row in table.rows.values) {
      final tag = row.tag(appEnvVar);
      if (tag == null || tag == mine || row.zombie || targets.containsKey(row.pid)) continue;
      final app = parseAppTag(tag);
      if (app == null || app.start == 'unknown' || table.aliveAt(app.pid, app.start)) continue;
      targets[row.pid] = (id: row.identity, label: row.command, owner: row.tag(ownerEnvVar) ?? 'app');
    }
    final ended = <SweptProcess>[];
    final survived = <SweptProcess>[];
    if (targets.isNotEmpty) {
      final roots = [for (final t in targets.values) t.id];
      final res = await _end(
        roots: roots,
        treeOnly: const [],
        // A group is ended only through its leader, alive with its start time (it is in the table now).
        leaders: [
          for (final r in roots)
            if (r.leadsGroup) r,
        ],
        env: true,
        first: scan,
      );
      final alive = {for (final s in res.survivors) s.pid};
      for (final t in targets.values) {
        final what = (pid: t.id.pid, label: t.label, why: 'left running by an earlier run');
        alive.contains(t.id.pid) ? survived.add(what) : ended.add(what);
      }
      for (final s in res.survivors) {
        final known = targets[s.pid];
        adoptKnown(
          s,
          SpawnSpec(
            owner: ProcessOwner.parse(known?.owner ?? 'app'),
            kind: ProcessKind.helper,
            exe: known?.label ?? '?',
            label: '${known?.label ?? 'process'} (left by an earlier run)',
          ),
        );
      }
      if (res.failure case final why?) {
        return SweepReport(ended: ended, survived: survived, leftAlone: leftAlone, failure: why);
      }
    }
    for (final f in swept) {
      try {
        f.deleteSync();
        final watch = File(f.path.replaceFirst(RegExp(r'ledger-(\d+)\.jsonl$'), r'watch-$1.list'));
        if (watch.path != f.path && watch.existsSync()) watch.deleteSync();
        final runPid = RegExp(r'ledger-(\d+)\.jsonl$').firstMatch(f.path)?.group(1);
        final jobs = Directory('$dir/jobs');
        if (runPid != null && jobs.existsSync()) {
          for (final j in jobs.listSync()) {
            if (j.uri.pathSegments.last.startsWith('$runPid-')) j.deleteSync();
          }
        }
      } on FileSystemException catch (e) {
        debugPrint('Process supervisor: could not delete the swept ledger ${f.path}: $e');
      }
    }
    final report = SweepReport(
      ended: ended,
      survived: survived,
      leftAlone: leftAlone,
      ledgers: [for (final f in swept) f.path],
    );
    if (!report.quiet) debugPrint('Process supervisor: launch sweep: $report');
    return report;
  }

  // ---------------------------------------------------------------- quitting

  @override
  Future<QuitReport> stopAll() async {
    final all = [..._list.values];
    final outcomes = await Future.wait([for (final r in all) stop(r)]);
    final report = QuitReport([
      for (var i = 0; i < all.length; i++)
        (id: all[i].id, label: all[i].spec.label, owner: all[i].spec.owner.key, outcome: outcomes[i]),
    ], at: DateTime.now());
    final dir = await ledgerDirectory;
    try {
      File('$dir/quit.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report.toJson()));
    } on FileSystemException catch (e) {
      debugPrint('Process supervisor: quit.json could not be written: $e');
    }
    if (!report.clean) {
      debugPrint(
        'NOT CLOSED at quit: ${[for (final e in report.entries)
          if (e.outcome is! Ended) '${e.label}: ${e.outcome}']}',
      );
    }
    if (report.clean && _list.isEmpty) _ledger.close();
    return report;
  }

  @override
  List<SupervisedChild> get children => [..._list.values];

  @override
  SupervisedChild? byPid(int pid) {
    for (final r in _list.values) {
      if (r.pid == pid) return r;
      if (r.state case ChildNotClosed(:final survivors) when survivors.any((s) => s.pid == pid)) return r;
    }
    return null;
  }

  // ---------------------------------------------------------------- the watchdog

  void _startWatchdog(String dir) {
    final self = _Self.it;
    if (self.start == 'unknown') {
      debugPrint('Process supervisor: no watchdog (this app\'s start time is unknown).');
      return;
    }
    final env = {
      for (final e in Platform.environment.entries)
        if (!e.key.startsWith('EVERYAI_')) e.key: e.value,
    };
    unawaited(
      Process.start(
        '/bin/sh',
        ['-c', watchdogScript, 'everyai-watchdog', '$pid', self.start, _ledger.watchPath, appTag, '2', '2'],
        mode: ProcessStartMode.detached,
        environment: env,
        includeParentEnvironment: false,
      ).then<void>(
        (_) {},
        onError: (Object e) =>
            debugPrint('Process supervisor: the watchdog did not start; a crash leaves children: $e'),
      ),
    );
  }
}

final class _EndResult {
  const _EndResult(this.targets, this.survivors, this.failure);
  final Set<ProcessIdentity> targets;
  final Set<ProcessIdentity> survivors;

  /// Why the end couldn't be checked (the table couldn't be read).
  final String? failure;

  List<int> get ended => [
    for (final p in targets)
      if (!survivors.contains(p)) p.pid,
  ]..sort();

  KillOutcome get outcome => switch (failure) {
    final why? => ScanFailed(why),
    null when survivors.isEmpty => Ended(ended),
    null => Survived([for (final s in survivors) s.pid]..sort(), 'still running after SIGKILL', ended: ended),
  };
}

// ------------------------------------------------------------------ the ledger file

final class _LedgerWriter {
  _LedgerWriter(this._sup);
  final _Supervisor _sup;
  String? _dir;
  final _pending = <LedgerLine>[];

  String get path => '$_dir/ledger-$pid.jsonl';
  String get watchPath => '$_dir/watch-$pid.list';

  void open(String dir) {
    _dir = dir;
    for (final l in _pending) {
      _write(l);
    }
    _pending.clear();
    writeWatchList();
  }

  void add(LedgerLine line) => _dir == null ? _pending.add(line) : _write(line);

  void _write(LedgerLine line) {
    final f = File(path);
    try {
      if (!f.existsSync()) {
        final self = _Self.it;
        f.writeAsStringSync(LedgerApp(pid: pid, start: self.start, pgid: self.pgid).encode());
      }
      f.writeAsStringSync(line.encode(), mode: FileMode.append);
    } on FileSystemException catch (e) {
      debugPrint('Process supervisor: the ledger could not be written ($e); a crash now would leave children.');
    }
  }

  /// Rewrites the watchdog's list (replaced whole, so the watchdog never reads half a list).
  void writeWatchList() {
    if (_dir == null) return;
    final live = [for (final r in _sup._list.values) ...r.liveProcesses];
    try {
      final tmp = File('$watchPath.tmp')..writeAsStringSync(watchList(live, appPgid: _Self.it.pgid));
      tmp.renameSync(watchPath);
    } on FileSystemException catch (e) {
      debugPrint('Process supervisor: the watchdog list could not be written: $e');
    }
  }

  /// Everything ended at quit: nothing for the next launch to sweep.
  void close() {
    for (final p in [path, watchPath]) {
      try {
        if (File(p).existsSync()) File(p).deleteSync();
      } on FileSystemException catch (e) {
        debugPrint('Process supervisor: could not delete $p: $e');
      }
    }
  }
}

// ------------------------------------------------------------------ the watchdog script

/// Waits for app `$1` (start token `$2`) to end, then ends what list `$3` names (one `<pgid|-> <pid> <start>` line
/// each; a group only through its leader, alive with its listed start time) and every process whose environment
/// has `EVERYAI_APP=$4` (Linux: any; macOS: where `ps -E` shows it): SIGTERM, `$6` seconds, SIGKILL to the same
/// groups and whatever is left. `$5` is how often it looks at the app.
@visibleForTesting
const watchdogScript = r'''
app=$1; start=$2; f=$3; tag=$4; every=${5:-2}; grace=${6:-2}
LC_ALL=C; export LC_ALL
st() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' \t\n' '___' | sed 's/^_*//;s/_*$//'; }
pg() { ps -o pgid= -p "$1" 2>/dev/null | tr -d ' \n'; }
while [ "$(st "$app")" = "$start" ]; do sleep "$every"; done
tagged() {
  if [ -d /proc/self ]; then
    for e in /proc/[0-9]*/environ; do
      tr '\0' '\n' < "$e" 2>/dev/null | grep -qxF "EVERYAI_APP=$tag" || continue
      p=${e#/proc/}; echo "${p%/environ}"
    done
  else
    ps -E -A -ww -o pid=,command= 2>/dev/null | awk -v t="EVERYAI_APP=$tag" '{for (i = 2; i <= NF; i++) if ($i == t) { print $1; break }}'
  fi
}
groups=""
term() {
  if [ -f "$f" ]; then
    while read -r g p t; do
      [ -n "$p" ] || continue
      [ "$(st "$p")" = "$t" ] || continue
      if [ "$g" != "-" ] && [ "$g" = "$p" ] && [ "$(pg "$p")" = "$g" ]; then
        kill -TERM -- "-$g" 2>/dev/null; groups="$groups $g"
      fi
      kill -TERM "$p" 2>/dev/null
    done < "$f"
  fi
  for p in $(tagged); do [ "$p" = "$$" ] || kill -TERM "$p" 2>/dev/null; done
}
killall_() {
  for g in $groups; do kill -KILL -- "-$g" 2>/dev/null; done
  if [ -f "$f" ]; then
    while read -r g p t; do
      [ -n "$p" ] || continue
      [ "$(st "$p")" = "$t" ] && kill -KILL "$p" 2>/dev/null
    done < "$f"
  fi
  for p in $(tagged); do [ "$p" = "$$" ] || kill -KILL "$p" 2>/dev/null; done
}
term; sleep "$grace"; killall_
rm -f "$f"
''';
