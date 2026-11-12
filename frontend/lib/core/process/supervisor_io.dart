// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'supervisor.dart';

/// In every spawned child's environment: its [SupervisedChild.id], so what it starts can be told apart from the
/// owner's other children by its tags.
const childEnvVar = 'EVERYAI_CHILD';

bool get _underTest => Platform.environment['FLUTTER_TEST'] == 'true';

ProcessSupervisor createSupervisor(SupervisorHooks hooks, {required String? ledgerDir, required bool app}) {
  // The app's own supervisor under `flutter test`: no watchdog and no sweep (each test process stays to itself).
  final quiet = app && ledgerDir == null && _underTest;
  return _Supervisor(
    quiet
        ? SupervisorHooks(scan: hooks.scan, signal: hooks.signal, timings: hooks.timings, launch: hooks.launch)
        : hooks,
    ledgerDir,
    app: app,
    sweeps: app && !quiet,
  );
}

// ------------------------------------------------------------------ this app

/// This process: its pid, group, user and start token, read once.
final class _Self {
  _Self._(this.pgid, this.uid, this.start);
  final int pgid;
  final int? uid;
  final String start;

  static final _Self it = _read();

  static _Self _read() {
    if (Platform.isWindows) return _Self._(pid, null, unknownStart);
    try {
      final r = Process.runSync('ps', ['-o', 'pgid=,uid=,lstart=', '-p', '$pid'], environment: const {'LC_ALL': 'C'});
      final m = RegExp(r'^\s*(\d+)\s+(\d+)\s+(.+?)\s*$').firstMatch('${r.stdout}');
      if (r.exitCode == 0 && m != null) {
        return _Self._(int.parse(m.group(1)!), int.parse(m.group(2)!), startToken(m.group(3)!));
      }
      debugPrint('Process supervisor: could not read this app\'s start time (ps exit ${r.exitCode}).');
    } on Object catch (e) {
      debugPrint('Process supervisor: could not read this app\'s start time: $e');
    }
    // Unknown: a sweep never takes this run for dead (its start can't be matched), so nothing of it is killed.
    return _Self._(pid, null, 'unknown');
  }

  /// The ledger, watch list and watchdog marker names of this run: by pid and start time, so a dead run with the
  /// same pid never shares them.
  String get suffix => '$pid-$start';
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
  final out = p.stdout.transform(const Utf8Decoder(allowMalformed: true)).join();
  final err = p.stderr.transform(const Utf8Decoder(allowMalformed: true)).join();
  const timedOut = -999999;
  final code = await p.exitCode.timeout(timeout, onTimeout: () => timedOut);
  if (code == timedOut) {
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
  final at = DateTime.now();
  if (Platform.isWindows) return _windowsScan(at);
  final r = await _raw('ps', ['-A', '-ww', '-o', 'pid=,ppid=,pgid=,uid=,stat=,lstart=,command=']);
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
  return Listed(ProcessList(rows), at: at, withEnv: env);
}

EnvView _procEnv(int pid) {
  try {
    return EnvRead(envTagsOf(File('/proc/$pid/environ').readAsStringSync(encoding: latin1)));
  } on FileSystemException {
    return const EnvHidden();
  }
}

Future<ProcessScan> _windowsScan(DateTime at) async {
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
                pgid: null,
                start: '${j['Created'] ?? 0}',
                command: '${j['CommandLine'] ?? j['Name'] ?? ''}',
              ),
        ];
        return rows.isEmpty ? const ScanFailed('the process list was empty') : Listed(ProcessList(rows), at: at);
      } on FormatException catch (e) {
        return ScanFailed('the process list did not parse: $e');
      }
  }
}

bool _osSignal(int pid, ProcessSignal signal) => Process.killPid(pid, signal);

// ------------------------------------------------------------------ the shared scan

@immutable
sealed class _ScanSlot {
  const _ScanSlot();
}

final class _ScanIdle extends _ScanSlot {
  const _ScanIdle(this.last, this.at);

  /// The last result and when that read began (none yet: [last] is a failure "not read yet").
  final ProcessScan last;
  final DateTime at;
}

final class _ScanBusy extends _ScanSlot {
  const _ScanBusy(this.future, this.startsAt, {required this.env});
  final Future<ProcessScan> future;

  /// When the read begins (later than asked when the rate limit holds it back).
  final DateTime startsAt;
  final bool env;
}

/// One reader of the process table for everyone: at most one read in flight, a caller wanting a table read after a
/// moment gets the read already under way when it began late enough, and reads are at least [minGap] apart.
final class _Scanner {
  _Scanner(this._read, this.minGap);
  final Future<ProcessScan> Function({required bool env}) _read;
  final Duration minGap;
  _ScanSlot _slot = _ScanIdle(const ScanFailed('not read yet'), DateTime.fromMillisecondsSinceEpoch(0));

  /// A table read no earlier than [after] (now by default), with environments when [env].
  Future<ProcessScan> get({bool env = false, DateTime? after}) async {
    final want = after ?? DateTime.now();
    while (true) {
      switch (_slot) {
        case _ScanBusy(:final future, :final startsAt, env: final e):
          if (!startsAt.isBefore(want) && (e || !env)) return future;
          await future;
        case _ScanIdle(:final last, :final at):
          if (last case Listed(withEnv: final e) when !at.isBefore(want) && (e || !env)) return last;
          final now = DateTime.now();
          final wait = minGap - now.difference(at);
          final startsAt = wait > Duration.zero ? now.add(wait) : now;
          final f = () async {
            if (wait > Duration.zero) await Future<void>.delayed(wait);
            final r = await _read(env: env);
            _slot = _ScanIdle(r, startsAt);
            return r;
          }();
          _slot = _ScanBusy(f, startsAt, env: env);
          return f;
      }
    }
  }
}

// ------------------------------------------------------------------ launching

/// How children are put in a session of their own here.
@immutable
sealed class _Launcher {
  const _Launcher();

  /// The command that starts [abs] (already resolved) with [args].
  (String, List<String>) command(String abs, List<String> args);

  /// The group a child started this way is in.
  ProcessGroup get group;
}

/// `everyai-exec`: setsid() + execv() (tool/exec_helper/main.c).
final class _Helper extends _Launcher {
  const _Helper(this.path);
  final String path;
  @override
  (String, List<String>) command(String abs, List<String> args) => (path, [abs, ...args]);
  @override
  ProcessGroup get group => const OwnGroup();
}

/// perl's setsid + exec (macOS ships /usr/bin/perl). Perl's own variables are kept from it and handed to the
/// program, so they can't change what perl does.
final class _Perl extends _Launcher {
  const _Perl();
  static const script =
      r'for (grep { /^EVERYAI_KEEP_/ } keys %ENV) { (my $k = $_) =~ s/^EVERYAI_KEEP_//; $ENV{$k} = delete $ENV{$_} } '
      r'POSIX::setsid(); exec { $ARGV[0] } @ARGV or do { print STDERR "$ARGV[0]: $!\n"; exit 127 }';
  @override
  (String, List<String>) command(String abs, List<String> args) =>
      ('/usr/bin/perl', ['-MPOSIX', '-e', script, '--', abs, ...args]);
  @override
  ProcessGroup get group => const OwnGroup();
}

/// util-linux `setsid`: execs in place (a Dart child never leads a group, so it doesn't fork).
final class _Setsid extends _Launcher {
  const _Setsid(this.path);
  final String path;
  @override
  (String, List<String>) command(String abs, List<String> args) => (path, [abs, ...args]);
  @override
  ProcessGroup get group => const OwnGroup();
}

/// None: the child shares the app's group (ended by its tree, never by group), or there are no groups (Windows).
final class _Plain extends _Launcher {
  const _Plain(this.why);
  final String why;
  @override
  (String, List<String>) command(String abs, List<String> args) => (abs, args);
  @override
  ProcessGroup get group => Platform.isWindows ? const NoGroups() : SharedGroup(_Self.it.pgid);
}

bool _isExecutable(String path) {
  final st = FileStat.statSync(path);
  return st.type == FileSystemEntityType.file && (st.mode & 0x49) != 0;
}

/// Where everyai-exec is: `EVERYAI_EXEC_HELPER`, the app bundle, then `frontend/.tools/` (development, tests).
String? _helperPath() {
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final cwd = Directory.current.path;
  for (final p in [
    ?Platform.environment['EVERYAI_EXEC_HELPER'],
    if (Platform.isMacOS) '$exeDir/../Resources/everyai-exec',
    if (Platform.isLinux) ...['$exeDir/everyai-exec', '$exeDir/lib/everyai-exec'],
    '$cwd/.tools/everyai-exec',
    '$cwd/frontend/.tools/everyai-exec',
  ]) {
    if (_isExecutable(p)) return p;
  }
  return null;
}

_Launcher _pickLauncher(LaunchVia via) {
  if (Platform.isWindows) return const _Plain('Windows has no process groups');
  String? setsid() => [
    for (final p in const ['/usr/bin/setsid', '/bin/setsid'])
      if (_isExecutable(p)) p,
  ].firstOrNull;
  switch (via) {
    case LaunchVia.helper:
      return switch (_helperPath()) {
        final p? => _Helper(p),
        null => const _Plain('everyai-exec is missing'),
      };
    case LaunchVia.perl:
      return _isExecutable('/usr/bin/perl') ? const _Perl() : const _Plain('no /usr/bin/perl');
    case LaunchVia.setsid:
      return switch (setsid()) {
        final p? => _Setsid(p),
        null => const _Plain('no setsid'),
      };
    case LaunchVia.shared:
      return const _Plain('asked for');
    case LaunchVia.auto:
      if (_helperPath() case final p?) return _Helper(p);
      if (Platform.isMacOS && _isExecutable('/usr/bin/perl')) return const _Perl();
      if (setsid() case final p?) return _Setsid(p);
      debugPrint('Process supervisor: no everyai-exec, perl or setsid; children share the app\'s process group.');
      return const _Plain('no launcher');
  }
}

/// [exe] as the absolute path the child's exec will run: a path as given (against [cwd]), else the first match on
/// the child's PATH. Never through a shell (no functions, builtins or aliases). Missing or not executable throws
/// like `Process.start`.
String _resolveExe(String exe, List<String> args, Map<String, String> env, String? cwd) {
  if (Platform.isWindows) return exe;
  final base = cwd ?? Directory.current.path;
  String abs(String p) => p.startsWith('/') ? p : '$base/$p';
  if (exe.contains('/')) {
    final p = abs(exe);
    if (FileSystemEntity.typeSync(p) != FileSystemEntityType.file) {
      throw ProcessException(exe, args, 'No such file or directory', 2);
    }
    if (!_isExecutable(p)) throw ProcessException(exe, args, 'Permission denied', 13);
    return p;
  }
  var denied = false;
  for (final dir in (env['PATH'] ?? '').split(':')) {
    final p = abs('${dir.isEmpty ? '.' : dir}/$exe');
    if (FileSystemEntity.typeSync(p) != FileSystemEntityType.file) continue;
    if (_isExecutable(p)) return p;
    denied = true;
  }
  throw ProcessException(exe, args, denied ? 'Permission denied' : 'No such file or directory', denied ? 13 : 2);
}

// ------------------------------------------------------------------ records

class _Record implements SupervisedChild {
  _Record(this._sup, this.id, this.spec, {required this.waitsOnExit});

  final _Supervisor _sup;
  @override
  final int id;
  @override
  final SpawnSpec spec;

  /// Whether its end comes from an exit future (spawned, or adopted with one); otherwise scans see it.
  final bool waitsOnExit;

  @override
  ChildState state = const ChildStarting();
  final _states = StreamController<ChildState>.broadcast(sync: true);
  final _landed = Completer<ProcessIdentity>();
  final _ended = Completer<ExitSeen>();

  // Facts kept once learned (not lifecycle: the state says where it is).
  int? _pid;
  DateTime? _launchedAt;
  ProcessGroup _launchGroup = const NoGroups();
  ProcessIdentity? _identity;

  /// The best it is known by: landed, or (ended before that) its pid and the group it was started in.
  ProcessIdentity? get lastKnown =>
      _identity ?? (_pid == null ? null : ProcessIdentity(pid: _pid!, start: unknownStart, group: _launchGroup));

  /// What runs below it (or ran below it and left, still alive), by pid + start time: refreshed by every shared
  /// scan, so a process that re-groups or is orphaned is still known as its.
  final tree = <int, ProcessIdentity>{};

  /// The child whose group or tree left this one running (its stop ends this one too).
  int? origin;

  /// The stop under way (a second stop joins it).
  Future<KillOutcome>? _stopping;

  @override
  Stream<ChildState> get states => _states.stream;
  @override
  Future<ProcessIdentity> get landed => _landed.future;
  @override
  Future<ExitSeen> get ended => _ended.future;
  @override
  int? get pid => _pid;

  /// What to signal: the landed identity, or (not landed) its pid with no start.
  ProcessIdentity? get identity => switch (state) {
    ChildRunning(:final id) || ChildTerming(:final id) || ChildKilling(:final id) => id,
    ChildLaunched(:final pid, :final group) ||
    ChildUnverified(:final pid, :final group) => ProcessIdentity(pid: pid, start: unknownStart, group: group),
    ChildNotClosed(:final survivors) => survivors.first,
    ChildExited() => lastKnown,
    ChildStarting() || ChildStartFailed() => null,
  };

  /// What the watchdog and the ledger must still end for it.
  List<LedgerProcess> get liveProcesses => [
    ...switch (state) {
      ChildLaunched(:final pid, :final at, :final group) || ChildUnverified(:final pid, :final at, :final group) => [
        (id: ProcessIdentity(pid: pid, start: unknownStart, group: group), at: at),
      ],
      ChildRunning(:final id) || ChildTerming(:final id) || ChildKilling(:final id) => [(id: id, at: _launchedAt)],
      ChildNotClosed(:final survivors) => [for (final s in survivors) (id: s, at: _launchedAt)],
      ChildStarting() || ChildExited() || ChildStartFailed() => const <LedgerProcess>[],
    },
    if (state.live)
      for (final t in tree.values) (id: t, at: null),
  ];

  void apply(ChildChange event) {
    final from = state;
    final next = applyChildEvent(from, event, label: '${spec.label} #$id');
    if (identical(next, from) || next == from) return;
    state = next;
    final ledger = _sup._files;
    switch (next) {
      case ChildLaunched(:final pid, :final at, :final group):
        _pid = pid;
        _launchedAt = at;
        _launchGroup = group;
        ledger.add(LedgerLaunch(id: id, pid: pid, at: at, ownGroup: group is OwnGroup));
      case ChildRunning(:final id):
        _identity = id;
        if (!_landed.isCompleted) _landed.complete(id);
        ledger.add(LedgerRun(id: this.id, identity: id));
      case ChildUnverified(:final why):
        debugPrint('UNVERIFIED: ${spec.label} #$id (pid $_pid): $why. It can only be ended by pid and tree.');
        ledger.add(LedgerState(id: id, state: next.name));
      case ChildExited(:final how):
        ledger.add(LedgerExit(id: id, code: next.code));
        if (!_ended.isCompleted) _ended.complete(how);
        _failLanding('${spec.label} ended before its start time was read');
      case ChildStartFailed(:final error):
        ledger.add(LedgerExit(id: id, code: null));
        _failLanding(error);
      case ChildNotClosed(:final survivors, :final reason):
        debugPrint('NOT CLOSED: ${spec.label} #$id: $survivors still running ($reason)');
        ledger.add(LedgerNotClosed(id: id, survivors: survivors, reason: reason));
      case ChildTerming() || ChildKilling():
        ledger.add(LedgerState(id: id, state: next.name));
      case ChildStarting():
        break;
    }
    _states.add(next);
    _sup._changed(this);
  }

  void _failLanding(String why) {
    if (_landed.isCompleted) return;
    _landed.completeError(StateError(why));
    _landed.future.ignore();
  }

  @override
  Future<KillOutcome> stop({StopTimings? timings}) => _sup.stop(this, timings: timings);

  @override
  bool signal(ProcessSignal signal) {
    final id = identity;
    if (id == null) return false;
    if (id.leadsGroup && !Platform.isWindows && _sup._signal(-id.pid, signal)) return true;
    return _sup._signal(id.pid, signal);
  }

  @override
  String toString() => '${spec.label} #$id ($state)';
}

final class _Spawned extends _Record implements SupervisedProcess {
  _Spawned(super.sup, super.id, super.spec) : super(waitsOnExit: true);

  late final Process _process;

  @override
  IOSink get stdin => _process.stdin;
  @override
  Stream<List<int>> get stdout => _process.stdout;
  @override
  Stream<List<int>> get stderr => _process.stderr;
  @override
  Future<int> get exitCode => _process.exitCode;
}

// ------------------------------------------------------------------ the supervisor's own life

@immutable
sealed class _SupState {
  const _SupState();
}

/// Nothing started yet: no files.
final class _SupIdle extends _SupState {
  const _SupIdle();
}

final class _SupOpening extends _SupState {
  const _SupOpening(this.done);
  final Future<String> done;
}

final class _SupOpen extends _SupState {
  const _SupOpen(this.dir);
  final String dir;
}

/// [stopAll] under way: nothing new is taken.
final class _SupQuitting extends _SupState {
  const _SupQuitting(this.done);
  final Future<QuitReport> done;
}

final class _SupClosed extends _SupState {
  const _SupClosed(this.report);
  final QuitReport report;
}

@immutable
sealed class _SweepState {
  const _SweepState();
}

final class _SweepNotRun extends _SweepState {
  const _SweepNotRun();
}

final class _SweepRunning extends _SweepState {
  const _SweepRunning(this.done);
  final Future<SweepReport> done;
}

final class _SweepDone extends _SweepState {
  const _SweepDone(this.report);
  final SweepReport report;
}

/// How often the shared scan runs: often while a child's start time is being read, a group's leftovers are
/// looked for or an end can only be seen by scans; seldom while children only run (their trees); never without.
@immutable
sealed class _Tick {
  const _Tick();
}

final class _TickOff extends _Tick {
  const _TickOff();
}

final class _TickOn extends _Tick {
  const _TickOn(this.timer, this.every);
  final Timer timer;
  final Duration every;
}

final class _Supervisor extends ProcessSupervisor {
  _Supervisor(this.hooks, String? dir, {required this.app, required this.sweeps}) : _dirChoice = dir {
    _scanner = _Scanner(
      ({required env}) => (hooks.scan ?? _osScan)(env: env),
      Platform.isWindows ? const Duration(seconds: 2) : const Duration(milliseconds: 20),
    );
  }

  final SupervisorHooks hooks;
  final bool app;
  final bool sweeps;
  String? _dirChoice;
  late final _Scanner _scanner;
  late final _launcher = _pickLauncher(hooks.launch);
  _SupState _state = const _SupIdle();
  _SweepState _sweepState = const _SweepNotRun();
  _Tick _tick = const _TickOff();
  var _ids = 0;
  final _list = <int, _Record>{};
  final _lingering = <_Record>[];
  late final _files = _Files(this);
  final _sweep = ValueNotifier<SweepReport?>(null);
  final _children = ValueNotifier<List<SupervisedChild>>(const []);

  StopTimings get t => hooks.timings;
  bool _signal(int pid, ProcessSignal s) => (hooks.signal ?? _osSignal)(pid, s);

  @override
  set ledgerDirectory(String path) {
    if (_state is! _SupIdle) debugPrint('Process supervisor: the ledger folder was set after first use; ignored.');
    if (_state is _SupIdle) _dirChoice = path;
  }

  @override
  Future<String> get ledgerDirectory => switch (_state) {
    _SupIdle() => _open(),
    _SupOpening(:final done) => done,
    _SupOpen(:final dir) => Future.value(dir),
    _SupQuitting() || _SupClosed() => Future.value(_files.dir ?? ''),
  };

  @override
  String get appTag => appTagOf(pid, _Self.it.start);

  static String appTagOf(int pid, String start) => '$pid:$start';

  @override
  Map<String, String> tagsFor(ProcessOwner owner) => {
    appEnvVar: appTag,
    ownerEnvVar: owner.key,
    if (owner case SessionOwner(:final id)) sessionTagEnvVar: id,
  };

  Future<String> _open() {
    final done = _openNow();
    _state = _SupOpening(done);
    return done;
  }

  Future<String> _openNow() async {
    var dir = _dirChoice;
    if (dir == null) {
      if (!app) {
        dir = '${Directory.systemTemp.path}/everyai-processes-$pid-${identityHashCode(this)}';
      } else if (_underTest) {
        dir = '${Directory.systemTemp.path}/everyai-processes-test-$pid';
      } else {
        try {
          dir = '${(await getApplicationSupportDirectory()).path}/processes';
        } on Object catch (e) {
          dir = '${Directory.systemTemp.path}/everyai-processes';
          debugPrint('Process supervisor: no app support folder ($e); the ledger is in $dir.');
        }
      }
    }
    try {
      Directory(dir).createSync(recursive: true);
    } on FileSystemException catch (e) {
      debugPrint('Process supervisor: the ledger folder $dir could not be made: $e');
    }
    // The same run reopened (a hot restart): go on with its ledger and take back what it still runs.
    final own = File(_Files.ledgerIn(dir));
    final LedgerFold? reopened = own.existsSync() ? LedgerFold.of(await own.readAsLines()) : null;
    if (reopened != null) _ids = reopened.lastId;
    _files.open(dir);
    if (_state is _SupOpening) _state = _SupOpen(dir);
    if (reopened != null && reopened.live.isNotEmpty) await _readopt(reopened);
    if (hooks.watchdog && !Platform.isWindows) _startWatchdog(dir);
    // After this start has returned (the sweep reads the folder through [ledgerDirectory] too).
    if (sweeps) scheduleMicrotask(() => unawaited(sweepPreviousRuns()));
    return dir;
  }

  Future<void> _readopt(LedgerFold fold) async {
    final scan = await _scanner.get();
    if (scan is! Listed) {
      debugPrint(
        'Process supervisor: this run\'s ledger names ${fold.live.length} children, but the table can\'t '
        'be read to take them back.',
      );
      return;
    }
    for (final c in fold.live) {
      for (final p in c.processes) {
        final row = scan.table.rows[p.id.pid];
        final ours = p.id.startKnown ? scan.table.alive(p.id) : p.at != null && scan.table.aliveNear(p.id.pid, p.at!);
        if (row == null || !ours || _list.values.any((r) => r.pid == p.id.pid)) continue;
        _adoptKnown(
          row.identity,
          SpawnSpec(owner: ProcessOwner.parse(c.owner), kind: ProcessKind.helper, exe: row.command, label: c.label),
        );
      }
    }
  }

  void _refuseWhenClosed(String what) {
    if (_state case _SupQuitting() || _SupClosed()) throw SupervisorClosed(what);
  }

  void _changed(_Record r) {
    final before = _list.length;
    if (!r.state.live) {
      _list.remove(r.id);
    } else if (r.state is! ChildStarting) {
      _list[r.id] = r; // an ended child whose group left processes is listed again (not closed)
    }
    if (_list.length != before || r.state is ChildStartFailed) _children.value = [..._list.values];
    _files.watchChanged();
    _retick();
  }

  // ---------------------------------------------------------------- spawn

  Map<String, String> _envFor(SpawnSpec spec, int id) {
    final env = <String, String>{};
    void put(String k, String v) {
      if (Platform.isWindows) env.removeWhere((x, _) => x.toUpperCase() == k.toUpperCase());
      env[k] = v;
    }

    if (spec.includeParentEnvironment) env.addAll(Platform.environment);
    for (final e in spec.env.entries) {
      put(e.key, e.value);
    }
    final hasSession = spec.env.keys.any(
      (k) => Platform.isWindows ? k.toUpperCase() == sessionTagEnvVar : k == sessionTagEnvVar,
    );
    for (final e in tagsFor(spec.owner).entries) {
      if (e.key == sessionTagEnvVar && hasSession) continue;
      put(e.key, e.value);
    }
    put(childEnvVar, '$id');
    return env;
  }

  @override
  Future<SupervisedProcess> spawn(SpawnSpec spec) async {
    _refuseWhenClosed('spawn ${spec.label}');
    final r = _Spawned(this, ++_ids, spec);
    _list[r.id] = r;
    try {
      await ledgerDirectory;
      _refuseWhenClosed('spawn ${spec.label}');
      _files.add(
        LedgerSpawn(
          id: r.id,
          exe: spec.exe,
          owner: spec.owner.key,
          kind: spec.kind.name,
          label: spec.label,
          outlivesApp: spec.outlivesApp,
          port: spec.port,
          detail: spec.detail,
        ),
      );
      final env = _envFor(spec, r.id);
      final abs = _resolveExe(spec.exe, spec.args, env, spec.cwd);
      final launcher = _launcher;
      if (launcher is _Perl) {
        for (final k in const ['PERL5OPT', 'PERL5LIB', 'PERLLIB', 'PERL5DB', 'PERL_UNICODE']) {
          if (env.remove(k) case final v?) env['EVERYAI_KEEP_$k'] = v;
        }
      }
      final (exe, args) = launcher.command(abs, spec.args);
      final at = DateTime.now();
      r._process = await Process.start(
        exe,
        args,
        environment: env,
        includeParentEnvironment: false,
        workingDirectory: spec.cwd,
      );
      r.apply(ChildSpawned(r._process.pid, at, group: launcher.group));
    } on Object catch (e) {
      r.apply(ChildFailedToStart('$e'));
      _list.remove(r.id);
      _children.value = [..._list.values];
      rethrow;
    }
    // Windows: no groups and no start times worth a PowerShell run each: it counts as landed by its pid.
    if (Platform.isWindows) {
      r.apply(
        ChildLanded(ProcessIdentity(pid: r._process.pid, start: unknownStart, group: const NoGroups()), DateTime.now()),
      );
    }
    unawaited(r._process.exitCode.then((code) => _exited(r, ExitCode(code))));
    _children.value = [..._list.values];
    return r;
  }

  void _exited(_Record r, ExitSeen how) {
    r.apply(ChildExitSeen(how, DateTime.now()));
    if (Platform.isWindows || r.spec.outlivesApp) return;
    // What its group or tree left running is looked for at the next scan.
    final id = r.lastKnown;
    if ((id != null && id.leadsGroup) || r.tree.isNotEmpty) {
      _lingering.add(r);
      _retick();
    }
  }

  // ---------------------------------------------------------------- adopt

  @override
  SupervisedChild adopt(int pid, SpawnSpec spec, {Future<int>? exitCode}) {
    _refuseWhenClosed('adopt ${spec.label} ($pid)');
    final r = _Record(this, ++_ids, spec, waitsOnExit: exitCode != null);
    _list[r.id] = r;
    unawaited(ledgerDirectory);
    _files.add(
      LedgerSpawn(
        id: r.id,
        exe: spec.exe,
        owner: spec.owner.key,
        kind: spec.kind.name,
        label: spec.label,
        outlivesApp: spec.outlivesApp,
        port: spec.port,
        detail: [?spec.detail, 'adopted'].join('; '),
      ),
    );
    // Its group is learned from the table (flutter_pty gives its child a session of its own).
    r.apply(
      ChildSpawned(pid, DateTime.now(), group: Platform.isWindows ? const NoGroups() : SharedGroup(_Self.it.pgid)),
    );
    if (Platform.isWindows) {
      r.apply(ChildLanded(ProcessIdentity(pid: pid, start: unknownStart, group: const NoGroups()), DateTime.now()));
    }
    if (exitCode != null) {
      unawaited(
        exitCode.then(
          (code) => _exited(r, ExitCode(code)),
          onError: (Object e) {
            // Its end is then seen by scans (the ticker treats it as one without an exit future).
            debugPrint('Process supervisor: ${spec.label}: its exit future failed ($e); scans will see its end.');
            _scanWatched.add(r);
            _retick();
          },
        ),
      );
    }
    _children.value = [..._list.values];
    return r;
  }

  /// Children whose exit future failed: seen gone by scans.
  final _scanWatched = <_Record>{};

  /// Lists a process already known by pid + start time (left behind by a child, a dead run, this run reopened).
  _Record _adoptKnown(ProcessIdentity id, SpawnSpec spec, {int? origin}) {
    final r = _Record(this, ++_ids, spec, waitsOnExit: false)..origin = origin;
    _list[r.id] = r;
    _files.add(LedgerSpawn(id: r.id, exe: spec.exe, owner: spec.owner.key, kind: spec.kind.name, label: spec.label));
    r.apply(ChildSpawned(id.pid, DateTime.now(), group: id.group));
    r.apply(ChildLanded(id, DateTime.now()));
    _children.value = [..._list.values];
    return r;
  }

  // ---------------------------------------------------------------- the ticker

  void _retick() {
    final live = _list.values.where((r) => r.state.live && !r.spec.outlivesApp);
    final fast =
        _lingering.isNotEmpty ||
        _scanWatched.isNotEmpty ||
        live.any(
          (r) =>
              r.state is ChildLaunched ||
              r.state is ChildUnverified ||
              r.state is ChildNotClosed ||
              (!r.waitsOnExit && r.state is ChildRunning),
        );
    final every = fast
        ? (Platform.isWindows ? const Duration(seconds: 2) : const Duration(milliseconds: 250))
        : live.isEmpty
        ? null
        : const Duration(seconds: 2);
    switch ((_tick, every)) {
      case (_TickOn(every: final e), final want?) when e == want:
        return;
      case (_TickOn(:final timer), _):
        timer.cancel();
      case (_TickOff(), _):
        break;
    }
    _tick = every == null ? const _TickOff() : _TickOn(Timer.periodic(every, (_) => unawaited(_onTick())), every);
  }

  Future<void> _onTick() async {
    final scan = await _scanner.get();
    switch (scan) {
      case Listed(:final table):
        _absorb(table);
      case ScanFailed(:final why):
        final now = DateTime.now();
        for (final r in [..._list.values]) {
          if (r.state case ChildLaunched(:final at) when now.difference(at) > const Duration(seconds: 3)) {
            r.apply(ChildUnverifiable('the process table could not be read: $why'));
          }
        }
    }
    _retick();
  }

  /// What a fresh table says about every child: landings, trees, ends only scans can see, leftovers.
  void _absorb(ProcessList table) {
    final now = DateTime.now();
    for (final r in [..._list.values]) {
      if (r._stopping != null) continue; // the stop reads the table itself
      switch (r.state) {
        case ChildLaunched(:final pid, :final at) || ChildUnverified(:final pid, :final at):
          final row = table.rows[pid];
          // A launcher sets the session up right after its own exec: until then the pid is in the app's group.
          final settling = switch (r.state) {
            ChildLaunched(group: OwnGroup()) => row != null && row.pgid != pid && now.difference(at).inSeconds < 3,
            _ => false,
          };
          if (row != null && !row.zombie && !settling) {
            final id = row.identity;
            if (r.state case ChildLaunched(group: OwnGroup()) when !id.leadsGroup) {
              debugPrint(
                'Process supervisor: ${r.spec.label} #${r.id} was meant to lead its own group but is in '
                '${id.pgid}; it is ended by its tree.',
              );
            }
            r.apply(ChildLanded(id, now));
          } else if (!r.waitsOnExit && row == null) {
            r.apply(ChildExitSeen(const SeenGone(), now));
          } else if (r.state is ChildLaunched && now.difference(at) > const Duration(seconds: 3)) {
            r.apply(const ChildUnverifiable('it is not in the process table, and its exit has not been reported'));
          }
        case ChildRunning(:final id) when !r.waitsOnExit || _scanWatched.contains(r):
          if (!table.alive(id)) r.apply(ChildExitSeen(const SeenGone(), now));
        case ChildNotClosed(:final survivors):
          if (!survivors.any(table.alive) && r.tree.values.every((p) => !table.alive(p))) {
            r.apply(ChildExitSeen(const SeenGone(), now));
          }
        default:
          break;
      }
      _refreshTree(r, table);
    }
    for (final r in [..._lingering]) {
      _lingering.remove(r);
      final id = r.lastKnown;
      final found = <int, ProcessIdentity>{
        for (final p in r.tree.values)
          if (table.alive(p)) p.pid: table.rows[p.pid]!.identity,
      };
      // Right after the exit no other group can have its id yet.
      final recent = switch (r.state) {
        ChildExited(:final at) => now.difference(at).inSeconds < 5,
        _ => false,
      };
      if (id != null && id.leadsGroup && recent) {
        for (final p in table.group(id.pid)) {
          final row = table.rows[p]!;
          if (!row.zombie && p != id.pid) found[p] ??= row.identity;
        }
      }
      for (final p in found.values) {
        if (_list.values.any((x) => x.pid == p.pid)) continue;
        final left = _adoptKnown(
          p,
          SpawnSpec(
            owner: r.spec.owner,
            kind: r.spec.kind,
            exe: table.rows[p.pid]?.command ?? '?',
            label: '${r.spec.label} (left running)',
          ),
          origin: r.id,
        );
        debugPrint('Process supervisor: ${r.spec.label} #${r.id} ended and left $left running; it is listed now.');
      }
    }
    _scanWatched.removeWhere((r) => !r.state.live);
  }

  void _refreshTree(_Record r, ProcessList table) {
    if (!r.state.live) return;
    final id = r.identity;
    var changed = false;
    for (final p in [...r.tree.keys]) {
      if (!table.alive(r.tree[p]!)) {
        r.tree.remove(p);
        changed = true;
      }
    }
    if (id != null && table.alive(id)) {
      for (final d in table.descendants(id.pid)) {
        final row = table.rows[d]!;
        if (row.zombie || r.tree.containsKey(d)) continue;
        r.tree[d] = row.identity;
        changed = true;
      }
    }
    if (changed) {
      _files.add(LedgerTree(id: r.id, processes: [...r.tree.values]));
      _files.watchChanged();
    }
  }

  // ---------------------------------------------------------------- stopping

  @override
  Future<KillOutcome> stop(SupervisedChild child, {StopTimings? timings}) {
    if (child is! _Record || !identical(child._sup, this)) {
      return Future.value(child.state.live ? const ScanFailed('not a child of this supervisor') : const Ended([]));
    }
    final r = child;
    if (r.state is ChildStartFailed) return Future.value(const Ended([]));
    final running = r._stopping;
    if (running != null) return running;
    final f = _stopRecord(r, timings ?? t);
    r._stopping = f;
    unawaited(
      f.whenComplete(() {
        r._stopping = null;
        _retick();
      }),
    );
    return f;
  }

  Future<KillOutcome> _stopRecord(_Record r, StopTimings tm) async {
    if (r.state is ChildStarting) await r.states.firstWhere((s) => s is! ChildStarting);
    final origins = [
      for (final x in _list.values)
        if (x.origin == r.id && !identical(x, r)) x,
    ];
    final fromOrigins = await Future.wait([for (final x in origins) stop(x, timings: tm)]);
    switch (r.state) {
      case ChildStartFailed() || ChildStarting():
        return KillOutcome.merge(fromOrigins);
      case ChildExited(:final at):
        // The program is gone; what its group or tree left running ends with it (the group only right after the
        // exit: no other group can have its id yet).
        final id = r.lastKnown;
        final recent = DateTime.now().difference(at) < const Duration(seconds: 5);
        if ((id == null || !id.leadsGroup || !recent) && r.tree.isEmpty) return KillOutcome.merge(fromOrigins);
        final res = await _end(
          roots: [...r.tree.values],
          leaders: [if (id != null && id.leadsGroup && recent) id],
          leaderless: true,
          rec: r,
          timings: tm,
        );
        return KillOutcome.merge([...fromOrigins, await _settle(r, res)]);
      default:
        break;
    }
    if (r.spec.politeStop case final polite? when r.state is! ChildNotClosed) await _polite(r, polite);
    if (!r.state.live) {
      // It took the hint; what it left is ended the same way.
      return KillOutcome.merge([...fromOrigins, await _stopRecord(r, tm)]);
    }
    final id = r.identity!;
    final res = await _end(
      roots: [id, ...r.tree.values],
      leaders: [if (id.leadsGroup) id],
      // A child followed since it started: its group is its own even once its leader has gone.
      leaderless: true,
      rec: r,
      timings: tm,
      childTag: r is _Spawned ? (childEnvVar, '${r.id}') : null,
      escapedSince: r._launchedAt,
    );
    return KillOutcome.merge([...fromOrigins, await _settle(r, res)]);
  }

  Future<void> _polite(_Record r, PoliteStop polite) async {
    try {
      await polite.run(r).timeout(polite.grace);
    } on TimeoutException {
      debugPrint('Process supervisor: ${r.spec.label} #${r.id}: its polite stop took over ${polite.grace}.');
    } on Object catch (e) {
      debugPrint('Process supervisor: ${r.spec.label} #${r.id}: its polite stop failed ($e); going on to SIGTERM.');
    }
    if (!r.state.live) return;
    await r.ended.timeout(polite.grace, onTimeout: () => const SeenGone());
  }

  /// Turns what [_end] found into the child's state and the outcome. A child that couldn't be checked or wasn't
  /// closed stays listed and is re-checked by the ticker until it is gone.
  Future<KillOutcome> _settle(_Record r, _EndResult res) async {
    if (res.failure case final why?) {
      // Not exited: only its own exit future or a check can say so.
      if (r.identity case final id? when r.state.live) r.apply(ChildSurvivors([id], 'could not check its end: $why'));
      return ScanFailed(why);
    }
    final survivors = res.survivors.toList();
    if (survivors.isEmpty) {
      if (r.state.live) {
        // Checked gone; for a child the app waits on, its own exit (and code) follows at once.
        if (r.waitsOnExit) await r._ended.future.timeout(const Duration(seconds: 1), onTimeout: () => const SeenGone());
        if (r.state.live) r.apply(ChildExitSeen(const SeenGone(), DateTime.now()));
      }
      r.tree.clear();
      return res.outcome;
    }
    const reason = 'still running after SIGKILL';
    r.apply(ChildSurvivors(survivors, reason));
    return Survived([for (final s in survivors) s.pid], reason, ended: res.ended);
  }

  @override
  Future<KillOutcome> stopOwner(ProcessOwner owner, {bool tagged = true, bool descendants = true}) async {
    final mine = [
      for (final r in _list.values)
        if (r.spec.owner == owner && !r.spec.outlivesApp) r,
    ];
    final since = [for (final r in mine) ?r._launchedAt]
        .fold<DateTime?>(null, (a, b) => a == null || b.isBefore(a) ? b : a);
    final outcomes = await Future.wait([for (final r in mine) stop(r)]);
    if (!tagged) return KillOutcome.merge(outcomes);
    final tag = appTag;
    final res = await _end(
      roots: const [],
      leaders: const [],
      tagged: (row) => row.tag(ownerEnvVar) == owner.key && row.tag(appEnvVar) == tag,
      descendants: descendants,
      escapedSince: since,
    );
    return KillOutcome.merge([...outcomes, res.outcome]);
  }

  @override
  Future<KillOutcome> killTree(int pid, {Duration? termWait}) async {
    if (byPid(pid) case final r?) return stop(r);
    if (Platform.isWindows) return _windowsKillTree(pid);
    final scan = await _scanner.get();
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
        return (await _end(roots: [id], leaders: [if (id.leadsGroup) id], timings: timings, first: scan)).outcome;
    }
  }

  Future<KillOutcome> _windowsKillTree(int pid) async {
    final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final r = await _raw('$root\\System32\\taskkill.exe', ['/PID', '$pid', '/T', '/F']);
    if (r case _RawDone(:final code) when code != 0 && code != 128) _signal(pid, ProcessSignal.sigkill);
    final scan = await _scanner.get();
    return switch (scan) {
      ScanFailed() => scan,
      Listed(:final table) when table.rows.containsKey(pid) => Survived([pid], 'still running after taskkill /F'),
      Listed() => Ended([pid]),
    };
  }

  /// Whether [row] may be something a child started that left its tree with its environment hidden (macOS
  /// platform binaries): orphaned, this user's, started since [since], and not a system service or app.
  bool _mayHaveEscaped(ScanRow row, DateTime since) {
    if (row.ppid != 1 || row.zombie || row.uid != _Self.it.uid || row.env is! EnvHidden) return false;
    final started = lstartTime(row.start);
    if (started == null || started.isBefore(since.subtract(const Duration(seconds: 2)))) return false;
    final c = row.command;
    const system = ['/System/', '/usr/libexec/', '/usr/sbin/', '/sbin/', '/Library/Apple/', '/Applications/'];
    if (system.any(c.startsWith) || c.startsWith('(')) return false;
    if (c.contains('.app/Contents/') || c.contains('.xpc/') || c.contains('.framework/')) return false;
    return !_list.values.any((r) => r.pid == row.pid || r.tree.containsKey(row.pid));
  }

  /// The verified kill: SIGTERM to the groups of [leaders], [roots] and what the table shows for them (their
  /// trees, what [tagged] or [childTag] matches); a wait that ends once all are gone; SIGKILL to what is left (and
  /// what appeared meanwhile); then a check by pid + start time.
  ///
  /// A group is signalled only once it is known to be ours: its leader is in the table with its start time (and
  /// then for the rest of this kill), or, with [leaderless], its leader is gone (a child followed since it
  /// started). A leader's pid with another start time means the group id is someone else's: never signalled.
  ///
  /// With [escapedSince] (macOS), orphans started since then whose environment is hidden can't be told apart from
  /// something the child started: they are not touched, and the outcome says [Unaccounted] instead of [Ended].
  Future<_EndResult> _end({
    required List<ProcessIdentity> roots,
    required List<ProcessIdentity> leaders,
    bool leaderless = false,
    bool Function(ScanRow row)? tagged,
    (String, String)? childTag,
    bool descendants = true,
    _Record? rec,
    StopTimings? timings,
    ProcessScan? first,
    DateTime? escapedSince,
  }) async {
    final tm = timings ?? t;
    final self = _Self.it;
    final targets = <int, ProcessIdentity>{};
    final candidates = [
      for (final l in leaders)
        if (l.pid > 1 && l.pid != self.pgid && l.leadsGroup && !Platform.isWindows) l,
    ];
    final groups = <int>{};
    final unaccounted = <int, ProcessIdentity>{};
    String? lastFailure;
    final appTagNow = appTag;
    bool tagMatch(ScanRow row) =>
        (tagged?.call(row) ?? false) ||
        (childTag != null && row.tag(childTag.$1) == childTag.$2 && row.tag(appEnvVar) == appTagNow);

    void collect(ProcessList table) {
      for (final l in [...candidates]) {
        final row = table.rows[l.pid];
        final ok = switch (row) {
          null => leaderless,
          ScanRow(zombie: true) => leaderless,
          final r => r.start == l.start || !l.startKnown ? r.pgid == l.pid : false,
        };
        if (ok) groups.add(l.pid);
        candidates.remove(l); // decided once: ours for this kill, or never
      }
      // An empty group is nothing to signal.
      groups.removeWhere((g) => table.group(g).every((p) => table.rows[p]!.zombie));
      final spare = table.ancestry(pid)..add(1);
      void add(int p) {
        final row = table.rows[p];
        if (row == null || row.zombie || spare.contains(p) || p <= 1) return;
        targets[p] ??= row.identity;
      }

      for (final r in roots) {
        if (table.alive(r)) {
          targets[r.pid] ??= table.rows[r.pid]!.identity;
          if (descendants) table.descendants(r.pid).forEach(add);
        }
      }
      for (final g in groups) {
        table.group(g).forEach(add);
      }
      for (final row in table.rows.values) {
        if (row.env is EnvRead && tagMatch(row)) {
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
      final s = await _scanner.get(after: DateTime.now());
      switch (s) {
        case ScanFailed(:final why):
          lastFailure = why;
          return null;
        case Listed(:final table):
          lastFailure = null;
          collect(table);
          unaccounted.removeWhere((_, p) => !table.alive(p));
          return {
            for (final p in targets.values)
              if (table.alive(p)) p,
          };
      }
    }

    void send(ProcessSignal sig) {
      for (final g in groups) {
        _signal(-g, sig);
      }
      for (final p in targets.values) {
        _signal(p.pid, sig);
      }
    }

    Future<Set<ProcessIdentity>?> waitGone(Duration budget) async {
      final until = DateTime.now().add(budget);
      while (true) {
        final now = await left();
        if (now != null && now.isEmpty) return now;
        if (DateTime.now().isAfter(until)) return now;
        await Future<void>.delayed(tm.poll);
      }
    }

    // The first look: plain, then (for tags, and escapes on macOS) once with environments.
    switch (first ?? await _scanner.get(after: DateTime.now())) {
      case ScanFailed(:final why):
        lastFailure = why;
        for (final r in roots) {
          targets[r.pid] = r; // blind: the roots as known
        }
        if (leaderless) groups.addAll([for (final l in candidates) l.pid]);
      case Listed(:final table):
        collect(table);
        final maybe = escapedSince == null
            ? const <ScanRow>[]
            : [
                for (final row in table.rows.values)
                  if (!targets.containsKey(row.pid) && _mayHaveEscaped(row, escapedSince)) row,
              ];
        final wantsEnv = tagged != null || (childTag != null && Platform.isLinux) || maybe.isNotEmpty;
        if (wantsEnv && !Platform.isWindows) {
          switch (await _scanner.get(env: true, after: DateTime.now())) {
            case Listed(table: final withEnv):
              collect(withEnv);
              for (final row in maybe) {
                final now = withEnv.rows[row.pid];
                if (now == null || targets.containsKey(row.pid)) continue;
                if (now.env is EnvHidden && withEnv.alive(row.identity)) unaccounted[row.pid] = row.identity;
              }
            case ScanFailed(:final why):
              lastFailure = 'environments could not be read: $why';
              for (final row in maybe) {
                unaccounted[row.pid] = row.identity;
              }
          }
        }
    }
    if (Platform.isWindows) {
      final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
      for (final p in targets.values) {
        await _raw('$root\\System32\\taskkill.exe', ['/PID', '${p.pid}', '/T', '/F']);
      }
      final now = await waitGone(tm.killWait);
      return _EndResult(targets.values.toSet(), now ?? targets.values.toSet(), now == null ? lastFailure : null, {});
    }
    if (targets.isEmpty && groups.isEmpty && lastFailure == null) {
      return _EndResult(const {}, const {}, null, unaccounted.values.toSet());
    }
    rec?.apply(ChildTermSent(DateTime.now()));
    send(ProcessSignal.sigterm);
    var now = await waitGone(tm.termGrace);
    if (now == null || now.isNotEmpty) {
      rec?.apply(ChildKillSent(DateTime.now()));
      send(ProcessSignal.sigkill);
      now = await waitGone(tm.killWait);
    }
    if (now == null) return _EndResult(targets.values.toSet(), targets.values.toSet(), lastFailure, {});
    return _EndResult(targets.values.toSet(), now, null, unaccounted.values.toSet());
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
    List<int>? stdinBytes,
    Encoding stdoutEncoding = systemEncoding,
    Encoding stderrEncoding = systemEncoding,
    int? maxOutputBytes,
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
    } on SupervisorClosed {
      rethrow;
    } on Object catch (e) {
      return StartFailed('$e');
    }
    final out = _Capture(maxOutputBytes), err = _Capture(maxOutputBytes);
    final outSub = p.stdout.listen(out.add, onDone: out.done.complete, onError: (Object _) {}, cancelOnError: false);
    final errSub = p.stderr.listen(err.add, onDone: err.done.complete, onError: (Object _) {}, cancelOnError: false);
    if (stdinBytes != null) p.stdin.add(stdinBytes);
    if (stdin != null) p.stdin.write(stdin);
    unawaited(p.stdin.close().catchError((Object _) {}));

    Future<void> drained(Duration within) =>
        Future.wait([out.done.future, err.done.future]).timeout(within, onTimeout: () => const []);
    Future<void> release() async {
      await outSub.cancel();
      await errSub.cancel();
    }

    final stopWhy = Completer<bool>(); // true: timed out, false: cancelled
    final timer = Timer(timeout, () {
      if (!stopWhy.isCompleted) stopWhy.complete(true);
    });
    if (cancel != null) {
      unawaited(
        cancel.then((_) {
          if (!stopWhy.isCompleted) stopWhy.complete(false);
        }, onError: (Object _) {}),
      );
    }
    final first = await Future.any<Object>([p.exitCode, stopWhy.future]);
    if (first is int) {
      // Exited: its pipes close with it, unless something it started still holds them.
      await drained(const Duration(milliseconds: 200));
      timer.cancel();
      if (out.done.isCompleted && err.done.isCompleted) {
        return Finished(first, out.output, err.output, stdoutEncoding: stdoutEncoding, stderrEncoding: stderrEncoding);
      }
      final left = await p.stop();
      await drained(const Duration(milliseconds: 300));
      await release();
      return Finished(
        first,
        out.output,
        err.output,
        stdoutEncoding: stdoutEncoding,
        stderrEncoding: stderrEncoding,
        leftRunning: left,
      );
    }
    timer.cancel();
    final kill = await p.stop();
    await drained(const Duration(milliseconds: 300));
    await release();
    return first == true
        ? TimedOut(kill, out.output, err.output, encoding: stdoutEncoding)
        : Cancelled(kill, out.output, err.output, encoding: stdoutEncoding);
  }

  @override
  Future<ProcessScan> scan({bool env = false}) => _scanner.get(env: env);

  // ---------------------------------------------------------------- the launch sweep

  @override
  ValueListenable<SweepReport?> get lastSweep => _sweep;

  @override
  Future<SweepReport> sweepPreviousRuns() {
    switch (_sweepState) {
      case _SweepRunning(:final done):
        return done;
      case _SweepDone(:final report):
        return Future.value(report);
      case _SweepNotRun():
        final done = _sweepNow().then((r) {
          _sweepState = _SweepDone(r);
          _sweep.value = r;
          return r;
        });
        _sweepState = _SweepRunning(done);
        return done;
    }
  }

  static final _ledgerName = RegExp(r'^ledger-(\d+(?:-[^/]+)?)\.jsonl$');

  Future<SweepReport> _sweepNow() async {
    final dir = await ledgerDirectory;
    final own = _files.ledgerPath;
    final files = <File>[];
    try {
      for (final e in Directory(dir).listSync()) {
        if (e is File && _ledgerName.hasMatch(e.uri.pathSegments.last) && e.path != own) files.add(e);
      }
    } on FileSystemException catch (e) {
      return SweepReport(failure: 'the ledger folder could not be read: $e');
    }
    final scan = await _scanner.get(env: true);
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
        lines = await f.readAsLines();
      } on FileSystemException {
        continue;
      }
      final fold = LedgerFold.of(lines);
      if (fold.app case final a?) {
        if (a.start != 'unknown' && table.aliveAt(a.pid, a.start)) continue; // still running
        if (a.start == 'unknown' && table.rows.containsKey(a.pid)) continue; // can't tell
      }
      swept.add(f);
      for (final c in fold.live) {
        for (final p in c.processes) {
          final row = table.rows[p.id.pid];
          if (row == null || row.zombie) continue;
          final ours = p.id.startKnown ? table.alive(p.id) : p.at != null && table.aliveNear(p.id.pid, p.at!);
          if (ours) {
            targets[p.id.pid] = (id: row.identity, label: c.label, owner: c.owner);
          } else {
            leftAlone.add((pid: p.id.pid, label: c.label, why: 'pid now belongs to another process (${row.command})'));
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
        // A group is ended only through its leader, alive with its start time (it is in the table now).
        leaders: [
          for (final r in roots)
            if (r.leadsGroup) r,
        ],
        first: scan,
      );
      final alive = {for (final s in res.survivors) s.pid};
      for (final t in targets.values) {
        final what = (pid: t.id.pid, label: t.label, why: 'left running by an earlier run');
        alive.contains(t.id.pid) ? survived.add(what) : ended.add(what);
      }
      for (final s in res.survivors) {
        final known = targets[s.pid];
        _adoptKnown(
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
      final suffix = _ledgerName.firstMatch(f.uri.pathSegments.last)!.group(1)!;
      for (final p in [f.path, '$dir/watch-$suffix.list', '$dir/watchdog-$suffix.pid']) {
        try {
          if (File(p).existsSync()) File(p).deleteSync();
        } on FileSystemException catch (e) {
          debugPrint('Process supervisor: could not delete $p after the sweep: $e');
        }
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
  Future<QuitReport> stopAll({StopTimings timings = StopTimings.quit}) {
    switch (_state) {
      case _SupQuitting(:final done):
        return done;
      case _SupClosed(:final report):
        return Future.value(report);
      case _SupIdle() || _SupOpening() || _SupOpen():
        final done = _quit(timings);
        _state = _SupQuitting(done);
        return done;
    }
  }

  Future<QuitReport> _quit(StopTimings timings) async {
    final all = [
      for (final r in _list.values)
        if (!r.spec.outlivesApp) r,
    ];
    final outcomes = await Future.wait([for (final r in all) stop(r, timings: timings)]);
    final report = QuitReport([
      for (var i = 0; i < all.length; i++)
        (id: all[i].id, label: all[i].spec.label, owner: all[i].spec.owner.key, outcome: outcomes[i]),
    ], at: DateTime.now());
    if (!report.clean) {
      debugPrint(
        'NOT CLOSED at quit: ${[for (final e in report.entries)
          if (e.outcome is! Ended) '${e.label}: ${e.outcome}']}',
      );
    }
    await _files.quit(report, clean: report.clean && _list.values.every((r) => r.spec.outlivesApp));
    if (_tick case _TickOn(:final timer)) timer.cancel();
    _tick = const _TickOff();
    _state = _SupClosed(report);
    return report;
  }

  @override
  List<SupervisedChild> get children => [..._list.values];

  @override
  ValueListenable<List<SupervisedChild>> get childrenListenable => _children;

  @override
  int liveCount(ProcessOwner owner) => _list.values.where((r) => r.spec.owner == owner).length;

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
    final marker = '$dir/watchdog-${self.suffix}.pid';
    // A hot restart: this run's watchdog is still there.
    if (File(marker).existsSync()) return;
    final env = {
      for (final e in Platform.environment.entries)
        if (!e.key.startsWith('EVERYAI_')) e.key: e.value,
    };
    unawaited(
      Process.start(
        '/bin/sh',
        ['-c', watchdogScript, 'everyai-watchdog', '$pid', self.start, _files.watchPath!, appTag, '2', '2', marker],
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

/// One pipe of a bounded run: chunks kept without copying, up to a cap.
final class _Capture {
  _Capture(this.cap);
  final int? cap;
  final _bytes = BytesBuilder(copy: false);
  final done = Completer<void>();
  var _cut = false;

  void add(List<int> chunk) {
    final room = cap == null ? chunk.length : cap! - _bytes.length;
    if (room >= chunk.length) {
      _bytes.add(chunk);
    } else {
      if (room > 0) _bytes.add(chunk.sublist(0, room));
      _cut = true;
    }
  }

  RunOutput get output => RunOutput(_bytes.toBytes(), truncated: _cut);
}

final class _EndResult {
  const _EndResult(this.targets, this.survivors, this.failure, this.unaccounted);
  final Set<ProcessIdentity> targets;
  final Set<ProcessIdentity> survivors;

  /// Why the end couldn't be checked (the table couldn't be read).
  final String? failure;

  /// Orphans that may be the child's, environment hidden: untouched, still running.
  final Set<ProcessIdentity> unaccounted;

  List<int> get ended => [
    for (final p in targets)
      if (!survivors.contains(p)) p.pid,
  ]..sort();

  KillOutcome get outcome => switch (failure) {
    final why? => ScanFailed(why),
    null when survivors.isNotEmpty => Survived(
      [for (final s in survivors) s.pid]..sort(),
      'still running after SIGKILL',
      ended: ended,
    ),
    null when unaccounted.isNotEmpty => Unaccounted(
      [for (final u in unaccounted) u.pid]..sort(),
      'orphaned while it ran, with environments the OS hides: may be its, so not touched',
      ended: ended,
    ),
    null => Ended(ended),
  };
}

// ------------------------------------------------------------------ the ledger files

enum _Flush { idle, scheduled }

/// The ledger and the watchdog's list, written off the caller's path: ledger lines are queued and appended in
/// batches, the watch list is rewritten (whole, by rename) at most every 30 ms. Files appear with the first line.
final class _Files {
  _Files(this._sup);
  final _Supervisor _sup;
  String? dir;
  final _pending = StringBuffer();
  var _ledgerFlush = _Flush.idle;
  var _watchFlush = _Flush.idle;
  Future<void> _tail = Future.value();

  static String ledgerIn(String dir) => '$dir/ledger-${_Self.it.suffix}.jsonl';
  String? get ledgerPath => dir == null ? null : ledgerIn(dir!);
  String? get watchPath => dir == null ? null : '$dir/watch-${_Self.it.suffix}.list';

  void open(String dir) {
    this.dir = dir;
    if (_pending.isNotEmpty) _scheduleLedger();
    watchChanged();
  }

  void add(LedgerLine line) {
    _pending.write(line.encode());
    if (dir != null) _scheduleLedger();
  }

  void _scheduleLedger() {
    if (_ledgerFlush == _Flush.scheduled) return;
    _ledgerFlush = _Flush.scheduled;
    _enqueue(() async {
      _ledgerFlush = _Flush.idle;
      final text = _pending.toString();
      _pending.clear();
      if (text.isEmpty) return;
      final f = File(ledgerPath!);
      final head = await f.exists() ? '' : LedgerApp(pid: pid, start: _Self.it.start).encode();
      await f.writeAsString('$head$text', mode: FileMode.append);
    });
  }

  void watchChanged() {
    if (dir == null || _watchFlush == _Flush.scheduled) return;
    _watchFlush = _Flush.scheduled;
    Timer(const Duration(milliseconds: 30), () {
      _enqueue(() async {
        _watchFlush = _Flush.idle;
        final live = [
          for (final r in _sup._list.values)
            if (!r.spec.outlivesApp) ...r.liveProcesses,
        ];
        final path = watchPath!;
        if (live.isEmpty && !await File(path).exists()) return; // nothing ever listed: no file
        final tmp = File('$path.tmp');
        await tmp.writeAsString(watchList(live));
        await tmp.rename(path);
      });
    });
  }

  void _enqueue(Future<void> Function() op) {
    _tail = _tail.then((_) => op()).catchError((Object e) {
      debugPrint('Process supervisor: the ledger could not be written ($e); a crash now would leave children.');
    });
  }

  /// At quit: `quit.json`, and (everything ended) the ledger and list deleted, after what was queued.
  Future<void> quit(QuitReport report, {required bool clean}) async {
    await _tail;
    final d = dir;
    if (d == null) return;
    final done = Completer<void>();
    _enqueue(() async {
      try {
        await File('$d/quit.json').writeAsString(const JsonEncoder.withIndent('  ').convert(report.toJson()));
        if (clean) {
          for (final p in [ledgerPath!, watchPath!]) {
            if (await File(p).exists()) await File(p).delete();
          }
        }
      } finally {
        done.complete();
      }
    });
    await done.future;
  }
}

// ------------------------------------------------------------------ the watchdog script

/// Waits for app `$1` (start token `$2`) to end, then ends what list `$3` names and everything below it: one
/// `<pgid|-> <pid> <start token|~epoch>` line each (a group only through its leader; `~epoch` matches a process that
/// started within 3 s of then), and every process whose environment has `EVERYAI_APP=$4` (Linux: any; macOS: where
/// `ps -E` shows it). SIGTERM, `$6` seconds, SIGKILL to the same groups and whatever is left of what it found. `$5`
/// is how often it looks at the app; `$7` is its marker file (its pid; gone when it is done).
@visibleForTesting
const watchdogScript = r'''
app=$1; start=$2; f=$3; tag=$4; every=${5:-2}; grace=${6:-2}; marker=$7
LC_ALL=C; export LC_ALL
[ -n "$marker" ] && echo $$ > "$marker"
st() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' \t\n' '___' | sed 's/^_*//;s/_*$//'; }
pg() { ps -o pgid= -p "$1" 2>/dev/null | tr -d ' \n'; }
epoch() {
  s=$(printf '%s' "$1" | tr '_' ' ')
  date -j -f '%a %b %e %T %Y' "$s" +%s 2>/dev/null || date -d "$s" +%s 2>/dev/null
}
matches() {
  now=$(st "$1"); [ -n "$now" ] || return 1
  case "$2" in
    ~*) e=${2#\~}; n=$(epoch "$now"); [ -n "$n" ] || return 1; d=$((n - e)); [ "$d" -ge -3 ] && [ "$d" -le 3 ] ;;
    *) [ "$now" = "$2" ] ;;
  esac
}
tree() {
  ps -A -o pid=,ppid= 2>/dev/null | awk -v r="$1" '{ k[$2] = k[$2] " " $1 }
    END { q = r; while (q != "") { n = split(q, a, " "); q = ""; for (i = 1; i <= n; i++) {
      m = split(k[a[i]], c, " "); for (j = 1; j <= m; j++) { print c[j]; q = q " " c[j] } } } }'
}
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
while [ "$(st "$app")" = "$start" ]; do sleep "$every"; done
v="$f.victims"; : > "$v"
groups=""
note() { [ "$1" = "$$" ] && return; t=$(st "$1"); [ -n "$t" ] && echo "$1 $t" >> "$v"; }
if [ -f "$f" ]; then
  while read -r g p t; do
    [ -n "$p" ] || continue
    matches "$p" "$t" || continue
    if [ "$g" != "-" ] && [ "$g" = "$p" ] && [ "$(pg "$p")" = "$g" ]; then groups="$groups $g"; fi
    note "$p"; for c in $(tree "$p"); do note "$c"; done
  done < "$f"
fi
for p in $(tagged); do note "$p"; for c in $(tree "$p"); do note "$c"; done; done
for g in $groups; do kill -TERM -- "-$g" 2>/dev/null; done
while read -r p t; do kill -TERM "$p" 2>/dev/null; done < "$v"
sleep "$grace"
for g in $groups; do kill -KILL -- "-$g" 2>/dev/null; done
while read -r p t; do [ "$(st "$p")" = "$t" ] && kill -KILL "$p" 2>/dev/null; done < "$v"
rm -f "$f" "$v" "$marker"
''';
