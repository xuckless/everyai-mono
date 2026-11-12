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

/// Runs [f] in the root zone (its timers, timeouts and scans on real time, whatever the caller's zone: a widget
/// test's fake time must not drive them) and answers in the caller's zone, errors too (they can't cross error
/// zones by themselves).
Future<T> _inRoot<T>(Future<T> Function() f) {
  final caller = Zone.current;
  if (identical(caller, Zone.root)) return f();
  final answer = Completer<T>();
  Zone.root.run(
    () => f().then<void>(
      (v) => caller.run(() => answer.complete(v)),
      onError: (Object e, StackTrace s) => caller.run(() => answer.completeError(e, s)),
    ),
  );
  return answer.future;
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

/// perl's setsid + exec (macOS ships /usr/bin/perl). Perl's own variables ([keys]) are kept from it and handed to
/// the program, so they can't change what perl does. Perl's exec is execvp, so a file without `#!` runs in /bin/sh.
final class _Perl extends _Launcher {
  const _Perl();
  static const keys = ['PERL5OPT', 'PERL5LIB', 'PERLLIB', 'PERL5DB', 'PERL_UNICODE'];
  static const script =
      r'for my $k (qw(PERL5OPT PERL5LIB PERLLIB PERL5DB PERL_UNICODE)) { '
      r'$ENV{$k} = delete $ENV{"EVERYAI_KEEP_$k"} if exists $ENV{"EVERYAI_KEEP_$k"} } '
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
/// the child's PATH. Never through a shell (no functions, builtins or aliases). What the launcher's exec would
/// refuse and can be checked here throws like `Process.start`: missing, a directory, not executable, a script whose
/// `#!` interpreter is missing or not executable. Left to the exec (exit 127 with the reason on stderr): a binary
/// for another architecture, a missing dynamic library, a file that changes in between.
String _resolveExe(String exe, List<String> args, Map<String, String> env, String? cwd) {
  if (Platform.isWindows) return exe;
  final base = cwd ?? Directory.current.path;
  String abs(String p) => p.startsWith('/') ? p : '$base/$p';
  String checked(String p) {
    final interp = _interpreterOf(p);
    if (interp != null && interp.startsWith('/') && !_isExecutable(interp)) {
      throw ProcessException(exe, args, 'bad interpreter: $interp', 2);
    }
    return p;
  }

  if (exe.contains('/')) {
    final p = abs(exe);
    final type = FileSystemEntity.typeSync(p);
    if (type == FileSystemEntityType.directory) throw ProcessException(exe, args, 'Is a directory', 21);
    if (type != FileSystemEntityType.file) throw ProcessException(exe, args, 'No such file or directory', 2);
    if (!_isExecutable(p)) throw ProcessException(exe, args, 'Permission denied', 13);
    return checked(p);
  }
  var denied = false;
  for (final dir in (env['PATH'] ?? '').split(':')) {
    final p = abs('${dir.isEmpty ? '.' : dir}/$exe');
    if (FileSystemEntity.typeSync(p) != FileSystemEntityType.file) continue;
    if (_isExecutable(p)) return checked(p);
    denied = true;
  }
  throw ProcessException(exe, args, denied ? 'Permission denied' : 'No such file or directory', denied ? 13 : 2);
}

/// The interpreter a `#!` script names, or null (a binary, or a file that can't be read: then exec decides).
String? _interpreterOf(String path) {
  try {
    final f = File(path).openSync();
    try {
      final head = f.readSync(256);
      if (head.length < 3 || head[0] != 0x23 || head[1] != 0x21) return null;
      final line = latin1.decode(head.sublist(2)).split('\n').first.trim();
      return line.isEmpty ? null : line.split(RegExp(r'\s+')).first;
    } finally {
      f.closeSync();
    }
  } on FileSystemException {
    return null;
  }
}

/// When the process in [row] started (macOS/Linux `lstart`; Windows a FILETIME), or null when unknown.
DateTime? _startedAt(ScanRow row) {
  if (!Platform.isWindows) return lstartTime(row.start);
  final ticks = int.tryParse(row.start);
  if (ticks == null || ticks == 0) return null;
  return DateTime.fromMicrosecondsSinceEpoch(ticks ~/ 10 - 11644473600000000);
}

/// Commands that are services, never something a child of the app started and left behind.
bool _looksLikeDaemon(String command) {
  const system = ['/System/', '/usr/libexec/', '/usr/sbin/', '/sbin/', '/Library/', '/Applications/', '/opt/'];
  if (system.any(command.startsWith) || command.startsWith('(') || command.startsWith('[')) return true;
  if (command.contains('.app/Contents/') || command.contains('.xpc/') || command.contains('.framework/')) return true;
  final name = command.split(' ').first.split('/').last;
  return RegExp(r'(d|Agent|Helper.*|Service|daemon|-server|server)$').hasMatch(name);
}

// ------------------------------------------------------------------ records

class _Record implements SupervisedChild {
  _Record(
    this._sup,
    this.id,
    this.spec, {
    required this.waitsOnExit,
    this.expectedStart,
    this.startedWithin,
    this.adoptedAt,
  });

  final _Supervisor _sup;
  @override
  final int id;
  @override
  final SpawnSpec spec;

  /// Whether its end comes from an exit future (spawned, or adopted with one); otherwise scans see it.
  final bool waitsOnExit;

  /// What an adoption expects of the process at its pid (not met: [ChildDisowned]).
  final String? expectedStart;
  final Duration? startedWithin;

  /// When it was adopted: [startedWithin] counts back from here, not from whenever a scan gets to look (a slow
  /// first scan must not disown the process just started).
  final DateTime? adoptedAt;
  bool get expects => expectedStart != null || startedWithin != null;

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

  /// When something listed in [tree] was last seen gone (no exit of it is ever seen): a sign that something below
  /// it may have left the tree too, unseen. Null while nothing has.
  DateTime? lastVanish;

  /// Its spawn line (repeated when the ledger is compacted).
  LedgerSpawn? spawnLine;

  // Facts added after the start ([annotate]).
  int? _port;
  String? _detail;

  @override
  int? get port => _port ?? spec.port;
  @override
  String? get detail => _detail ?? spec.detail;

  @override
  void annotate({String? detail, int? port}) {
    if (detail == null && port == null) return;
    _detail = detail ?? _detail;
    _port = port ?? _port;
    _sup._files.add(LedgerNote(id: id, port: port, detail: detail));
  }

  /// When its tree was last written to the ledger, and whether it changed since.
  DateTime treeWrittenAt = DateTime.fromMillisecondsSinceEpoch(0);
  _TreeLine treeLine = _TreeLine.written;

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
    ChildStarting() || ChildStartFailed() || ChildDisowned() => null,
  };

  /// What the watchdog and the ledger must still end for it.
  List<LedgerProcess> get liveProcesses => [
    ...switch (state) {
      ChildLaunched(:final pid, :final at, :final group) || ChildUnverified(:final pid, :final at, :final group) => [
        (id: ProcessIdentity(pid: pid, start: unknownStart, group: group), at: at),
      ],
      ChildRunning(:final id) || ChildTerming(:final id) || ChildKilling(:final id) => [(id: id, at: _launchedAt)],
      ChildNotClosed(:final survivors) => [for (final s in survivors) (id: s, at: _launchedAt)],
      ChildStarting() || ChildExited() || ChildStartFailed() || ChildDisowned() => const <LedgerProcess>[],
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
        _sup._ownerLaunched(spec.owner, at);
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
      case ChildDisowned(:final pid, :final why):
        debugPrint('Process supervisor: ${spec.label} #$id: pid $pid is not the process expected ($why); not touched.');
        ledger.add(LedgerState(id: id, state: next.name));
        ledger.add(LedgerExit(id: id, code: null));
        if (!_ended.isCompleted) _ended.complete(const SeenGone());
        _failLanding('pid $pid is not the process expected: $why');
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

/// A child's tree in the ledger: written, or changed since (written at the next chance, at most every 3 s).
enum _TreeLine { written, changed }

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

/// [stopAll] under way: nothing new is taken, except quit steps (`runBounded(duringQuit: true)`).
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
  _Supervisor(this.hooks, String? dir, {required this.app, required this.sweeps})
    : _dirChoice = dir,
      _treeEvery = hooks.treeEvery {
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
  Duration _treeEvery;

  /// The ticker's interval while only children not closed or unverified need it: doubles per tick up to 5 s.
  Duration _backoff = _fastTick;
  static const _fastTick = Duration(milliseconds: 250);
  static const _slowest = Duration(seconds: 5);

  /// Per owner: when its first child of this run started, and whether something left a tree of its unseen.
  final _owners = <String, ({DateTime since, bool escapeHint})>{};

  /// What dead runs' ledgers named (the sweep's read).
  var _previous = const <LedgerEntry>[];

  StopTimings get t => hooks.timings;

  void _ownerLaunched(ProcessOwner owner, DateTime at) {
    final o = _owners[owner.key];
    if (o == null || at.isBefore(o.since)) _owners[owner.key] = (since: at, escapeHint: o?.escapeHint ?? false);
  }

  void _ownerEscapeHint(ProcessOwner owner) {
    final o = _owners[owner.key];
    if (o != null) _owners[owner.key] = (since: o.since, escapeHint: true);
  }

  @override
  Duration get treeScanInterval => _treeEvery;

  @override
  set treeScanInterval(Duration every) {
    // In the root zone, whatever the caller's: fake time in widget tests must not drive real timeouts.
    Zone.root.run(() {
      _treeEvery = every < _fastTick ? _fastTick : every;
      _retick();
    });
  }

  @override
  List<LedgerEntry> get ledgerEntries => ledgerEntriesOf([
    for (final r in _list.values)
      if (r.liveProcesses case final p when p.isNotEmpty)
        (
          id: r.id,
          label: r.spec.label,
          owner: r.spec.owner.key,
          kind: r.spec.kind.name,
          port: r.port,
          detail: r.detail,
          processes: p,
        ),
  ]);

  @override
  List<LedgerEntry> get previousRunEntries => _previous;
  bool _signal(int pid, ProcessSignal s) => (hooks.signal ?? _osSignal)(pid, s);

  @override
  set ledgerDirectory(String path) {
    if (_state is! _SupIdle) debugPrint('Process supervisor: the ledger folder was set after first use; ignored.');
    if (_state is _SupIdle) _dirChoice = path;
  }

  @override
  Future<String> get ledgerDirectory => _inRoot(() => _ledgerDirectory);

  Future<String> get _ledgerDirectory => switch (_state) {
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
    // A folder of its own (tests, a temp one): made with the first line, removed again whenever it holds nothing.
    final owned = _dirChoice == null && (!app || _underTest);
    _files.removeDirWhenEmpty = owned;
    if (owned) {
      _files.markFolderAbsent(dir);
      if (app) await _clearDeadTestFolders();
    } else {
      try {
        Directory(dir).createSync(recursive: true);
      } on FileSystemException catch (e) {
        debugPrint('Process supervisor: the ledger folder $dir could not be made: $e');
      }
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

  /// `flutter test`: the folders of test processes that have ended (they quit without a stop) go.
  Future<void> _clearDeadTestFolders() async {
    final scan = await _scanner.get();
    if (scan is! Listed) return;
    final name = RegExp(r'^everyai-processes-test-(\d+)$');
    try {
      for (final e in Directory.systemTemp.listSync()) {
        final m = name.firstMatch(e.uri.pathSegments.where((x) => x.isNotEmpty).last);
        if (e is! Directory || m == null) continue;
        final owner = int.parse(m.group(1)!);
        if (owner == pid || scan.table.rows.containsKey(owner)) continue;
        e.deleteSync(recursive: true);
      }
    } on FileSystemException catch (e) {
      debugPrint('Process supervisor: old test folders could not be cleared: $e');
    }
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
          SpawnSpec(
            owner: ProcessOwner.parse(c.owner),
            kind: ProcessKind.values.asNameMap()[c.kind] ?? ProcessKind.helper,
            exe: row.command,
            label: c.label,
            port: c.port,
            detail: c.detail,
          ),
        );
      }
    }
  }

  void _refuseWhenClosed(String what, {bool duringQuit = false}) {
    switch (_state) {
      case _SupClosed():
        throw SupervisorClosed(what);
      case _SupQuitting() when !duringQuit:
        throw SupervisorClosed(what);
      default:
        break;
    }
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
    if (_list.isEmpty) _files.idle();
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
    // A user's terminal is never the session's: no session tag, inherited or passed.
    if (spec.owner is TerminalOwner) {
      env.removeWhere((k, _) => (Platform.isWindows ? k.toUpperCase() : k) == sessionTagEnvVar);
    }
    return env;
  }

  @override
  Future<SupervisedProcess> spawn(SpawnSpec spec) => _inRoot(() => _spawn(spec, duringQuit: false));

  Future<SupervisedProcess> _spawn(SpawnSpec spec, {required bool duringQuit}) async {
    _refuseWhenClosed('spawn ${spec.label}', duringQuit: duringQuit);
    final r = _Spawned(this, ++_ids, spec);
    _list[r.id] = r;
    final first = _files.watchState == _WatchFile.none;
    try {
      await ledgerDirectory;
      _refuseWhenClosed('spawn ${spec.label}', duringQuit: duringQuit);
      final env = _envFor(spec, r.id);
      final abs = _resolveExe(spec.exe, spec.args, env, spec.cwd);
      // On disk before the process exists: a crash right after the start leaves a trace for the next sweep.
      await _files.addNow(
        r.spawnLine = LedgerSpawn(
          id: r.id,
          exe: spec.exe,
          owner: spec.owner.key,
          kind: spec.kind.name,
          label: spec.label,
          port: spec.port,
          detail: spec.detail,
        ),
      );
      final launcher = _launcher;
      if (launcher is _Perl) {
        for (final k in _Perl.keys) {
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
      // The first child: the watchdog's list exists and names it before spawn returns (later ones follow within
      // 30 ms; a crash in between leaves them to the next launch's sweep, by their tags).
      if (first) await _files.flushWatch();
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
    if (Platform.isWindows) return;
    // What its group or tree left running is looked for at the next scan.
    final id = r.lastKnown;
    if ((id != null && id.leadsGroup) || r.tree.isNotEmpty) {
      _lingering.add(r);
      _retick();
    }
  }

  // ---------------------------------------------------------------- adopt

  @override
  SupervisedChild adopt(
    int pid,
    SpawnSpec spec, {
    Future<int>? exitCode,
    String? expectedStart,
    Duration? startedWithin,
  }) {
    // In the root zone, whatever the caller's: fake time in widget tests must not drive real timeouts.
    return Zone.root.run(() {
      _refuseWhenClosed('adopt ${spec.label} ($pid)');
      final r = _Record(
        this,
        ++_ids,
        spec,
        waitsOnExit: exitCode != null,
        expectedStart: expectedStart,
        startedWithin: startedWithin,
        adoptedAt: DateTime.now(),
      );
      _list[r.id] = r;
      unawaited(ledgerDirectory);
      _files.add(
        r.spawnLine = LedgerSpawn(
          id: r.id,
          exe: spec.exe,
          owner: spec.owner.key,
          kind: spec.kind.name,
          label: spec.label,
          port: spec.port,
          detail: [?spec.detail, 'adopted'].join('; '),
        ),
      );
      // Its group is learned from the table (flutter_pty gives its child a session of its own).
      r.apply(
        ChildSpawned(pid, DateTime.now(), group: Platform.isWindows ? const NoGroups() : SharedGroup(_Self.it.pgid)),
      );
      // Windows lands by pid alone, unless the caller wants the process checked first.
      if (Platform.isWindows && !r.expects) {
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
    });
  }

  @override
  Future<DetachedLaunch> launchDetached(
    String exe,
    List<String> args, {
    Map<String, String> env = const {},
    bool includeParentEnvironment = true,
    String? cwd,
    String? label,
  }) {
    // In the root zone, whatever the caller's: fake time in widget tests must not drive real timeouts.
    return _inRoot(() async {
      bool ours(String k) => (Platform.isWindows ? k.toUpperCase() : k).startsWith('EVERYAI_');
      final full = <String, String>{
        if (includeParentEnvironment)
          for (final e in Platform.environment.entries)
            if (!ours(e.key)) e.key: e.value,
      };
      for (final e in env.entries) {
        if (ours(e.key)) continue;
        if (Platform.isWindows) full.removeWhere((k, _) => k.toUpperCase() == e.key.toUpperCase());
        full[e.key] = e.value;
      }
      final Process p;
      try {
        final abs = _resolveExe(exe, args, full, cwd);
        p = await Process.start(
          abs,
          args,
          environment: full,
          includeParentEnvironment: false,
          workingDirectory: cwd,
          mode: ProcessStartMode.detached,
        );
      } on Object catch (e) {
        return LaunchFailed('$e');
      }
      if (_state case _SupOpen() || _SupOpening() || _SupQuitting()) {
        _files.add(LedgerDetached(pid: p.pid, exe: exe, label: label ?? exe, at: DateTime.now()));
      }
      return Launched(p.pid);
    });
  }

  /// Children whose exit future failed: seen gone by scans.
  final _scanWatched = <_Record>{};

  /// Lists a process already known by pid + start time (left behind by a child, a dead run, this run reopened).
  _Record _adoptKnown(ProcessIdentity id, SpawnSpec spec, {int? origin}) {
    final r = _Record(this, ++_ids, spec, waitsOnExit: false)..origin = origin;
    _list[r.id] = r;
    _files.add(
      r.spawnLine = LedgerSpawn(
        id: r.id,
        exe: spec.exe,
        owner: spec.owner.key,
        kind: spec.kind.name,
        label: spec.label,
        port: spec.port,
        detail: spec.detail,
      ),
    );
    r.apply(ChildSpawned(id.pid, DateTime.now(), group: id.group));
    r.apply(ChildLanded(id, DateTime.now()));
    _children.value = [..._list.values];
    return r;
  }

  // ---------------------------------------------------------------- the ticker

  /// What the ticker is for now: something new to read (a start time, leftovers, an end only scans see), only
  /// children not closed or unverified (backing off), only running children (their trees), or nothing.
  ({bool fresh, bool stuck, bool running}) _needs() {
    final live = _list.values.where((r) => r.state.live);
    return (
      fresh:
          _lingering.isNotEmpty ||
          _scanWatched.isNotEmpty ||
          live.any((r) => r.state is ChildLaunched || (!r.waitsOnExit && r.state is ChildRunning)),
      stuck: live.any((r) => r.state is ChildNotClosed || r.state is ChildUnverified),
      running: live.isNotEmpty,
    );
  }

  void _retick() {
    final n = _needs();
    final Duration? every;
    if (n.fresh) {
      _backoff = _fastTick;
      every = Platform.isWindows ? const Duration(seconds: 2) : _fastTick;
    } else if (n.stuck) {
      every = _backoff < _treeEvery ? _backoff : _treeEvery;
    } else {
      _backoff = _fastTick;
      every = n.running ? _treeEvery : null;
    }
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
    final now = DateTime.now();
    switch (scan) {
      case Listed(:final table):
        _absorb(table);
      case ScanFailed(:final why):
        for (final r in [..._list.values]) {
          if (r.state case ChildLaunched(:final at) when now.difference(at) > const Duration(seconds: 3)) {
            r.apply(
              r.expects
                  ? ChildNotOurs('could not be checked: $why')
                  : ChildUnverifiable('the process table could not be read: $why'),
            );
          }
        }
    }
    final n = _needs();
    if (!n.fresh && n.stuck) {
      final doubled = _backoff * 2;
      _backoff = doubled > _slowest ? _slowest : doubled;
    }
    _retick();
  }

  /// Whether the process in [row] is the one [r]'s adopter expects; the reason when not.
  String? _mismatch(_Record r, ScanRow row, DateTime now) {
    if (r.expectedStart case final want? when row.start != want) return 'started ${row.start}, not $want';
    if (r.startedWithin case final within?) {
      final started = _startedAt(row);
      if (started == null) return 'its start time is unknown';
      // Measured from the adoption (the scan may come much later); a second of slack for whole-second start times.
      final adopted = r.adoptedAt ?? now;
      if (started.isBefore(adopted.subtract(within).subtract(const Duration(seconds: 1)))) {
        return 'started at $started, more than $within before it was adopted at $adopted';
      }
      // A process that started after the adoption has reused the pid of ours.
      if (started.isAfter(adopted.add(const Duration(seconds: 2)))) {
        return 'started at $started, after it was adopted at $adopted';
      }
    }
    return null;
  }

  /// What a fresh table says about every child: landings, trees, ends only scans can see, leftovers.
  void _absorb(ProcessList table) {
    final now = DateTime.now();
    for (final r in [..._list.values]) {
      // The stop reads the table itself (but an adoption's check is still made here: the stop waits for it).
      if (r._stopping != null && r.state is! ChildLaunched) continue;
      switch (r.state) {
        case ChildLaunched(:final pid, :final at) || ChildUnverified(:final pid, :final at):
          final row = table.rows[pid];
          // A launcher sets the session up right after its own exec: until then the pid is in the app's group.
          final settling = switch (r.state) {
            ChildLaunched(group: OwnGroup()) => row != null && row.pgid != pid && now.difference(at).inSeconds < 3,
            _ => false,
          };
          if (row != null && !row.zombie && !settling && r.expects) {
            if (_mismatch(r, row, now) case final why?) {
              r.apply(ChildNotOurs(why));
              continue;
            }
          }
          if (row != null && !row.zombie && !settling) {
            final id = row.identity;
            if (r.state case ChildLaunched(group: OwnGroup()) when !id.leadsGroup) {
              debugPrint(
                'Process supervisor: ${r.spec.label} #${r.id} was meant to lead its own group but is in '
                '${id.pgid}; it is ended by its tree.',
              );
            }
            r.apply(ChildLanded(id, now));
          } else if (r.expects && row == null) {
            r.apply(const ChildNotOurs('no process has that pid'));
          } else if (!r.waitsOnExit && row == null) {
            r.apply(ChildExitSeen(const SeenGone(), now));
          } else if (r.state is ChildLaunched && now.difference(at) > const Duration(seconds: 3)) {
            r.apply(
              r.expects
                  ? const ChildNotOurs('could not be checked in time')
                  : const ChildUnverifiable('it is not in the process table, and its exit has not been reported'),
            );
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
        // Gone without an exit anyone saw: whatever it started may have left the tree as well.
        r.lastVanish = DateTime.now();
        _ownerEscapeHint(r.spec.owner);
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
      r.treeLine = _TreeLine.changed;
      _files.watchChanged();
    }
    // The ledger gets the tree at most every 3 s per child (the watch list, which the watchdog reads, at once).
    final now = DateTime.now();
    if (r.treeLine == _TreeLine.changed && now.difference(r.treeWrittenAt) >= const Duration(seconds: 3)) {
      _files.add(LedgerTree(id: r.id, processes: [...r.tree.values]));
      r.treeLine = _TreeLine.written;
      r.treeWrittenAt = now;
    }
  }

  // ---------------------------------------------------------------- stopping

  @override
  Future<KillOutcome> stop(SupervisedChild child, {StopTimings? timings}) {
    // In the root zone, whatever the caller's: fake time in widget tests must not drive real timeouts.
    return _inRoot(() {
      if (child is! _Record || !identical(child._sup, this)) {
        return Future.value(child.state.live ? const ScanFailed('not a child of this supervisor') : const Ended([]));
      }
      final r = child;
      if (r.state case ChildStartFailed() || ChildDisowned()) return Future.value(const Ended([]));
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
    });
  }

  Future<KillOutcome> _stopRecord(_Record r, StopTimings tm) async {
    if (r.state is ChildStarting) await r.states.firstWhere((s) => s is! ChildStarting);
    // An adoption that must be checked first is never signalled before it is.
    if (r.expects && r.state is ChildLaunched) {
      _retick();
      await r.states
          .firstWhere((s) => s is! ChildLaunched)
          .timeout(const Duration(seconds: 5), onTimeout: () => r.state);
      if (r.state is ChildLaunched) r.apply(const ChildNotOurs('could not be checked in time'));
    }
    if (r.state is ChildDisowned) return const Ended([]);
    final origins = [
      for (final x in _list.values)
        if (x.origin == r.id && !identical(x, r)) x,
    ];
    final fromOrigins = await Future.wait([for (final x in origins) stop(x, timings: tm)]);
    switch (r.state) {
      case ChildStartFailed() || ChildStarting() || ChildDisowned():
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
    // A fresh look at its tree first: what vanished from it since the last tick is the sign of an escape.
    final first = await _scanner.get(after: DateTime.now());
    if (first case Listed(:final table)) _refreshTree(r, table);
    final res = await _end(
      first: first,
      roots: [id, ...r.tree.values],
      leaders: [if (id.leadsGroup) id],
      // A child followed since it started: its group is its own even once its leader has gone.
      leaderless: true,
      rec: r,
      timings: tm,
      childTag: r is _Spawned ? (childEnvVar, '${r.id}') : null,
      escapedSince: r.lastVanish == null ? null : r._launchedAt,
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
  Future<KillOutcome> stopOwner(ProcessOwner owner, {bool tagged = true, bool descendants = true}) {
    // In the root zone, whatever the caller's: fake time in widget tests must not drive real timeouts.
    return _inRoot(() async {
      final mine = [
        for (final r in _list.values)
          if (r.spec.owner == owner) r,
      ];
      final outcomes = await Future.wait([for (final r in mine) stop(r)]);
      // Kept past its children's records: when its first child started, and whether a tree of its lost something.
      final seen = _owners[owner.key];
      final since = seen != null && seen.escapeHint ? seen.since : null;
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
    });
  }

  @override
  Future<KillOutcome> killTree(int pid, {Duration? termWait, String? expectedStart}) {
    // In the root zone, whatever the caller's: fake time in widget tests must not drive real timeouts.
    return _inRoot(() async {
      if (expectedStart != null) {
        // The kill's own look at the table decides: gone or reused means nothing is signalled.
        final look = await _scanner.get(after: DateTime.now());
        switch (look) {
          case ScanFailed():
            return look; // can't tell whose it is: nothing signalled
          case Listed(:final table):
            final row = table.rows[pid];
            if (row == null || row.zombie) return Ended(const [], skipped: 'pid $pid is not running');
            if (row.start != expectedStart) {
              return Ended(const [], skipped: 'pid $pid is another process now (started ${row.start})');
            }
        }
      }
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
          if (expectedStart != null && row.start != expectedStart) {
            return Ended(const [], skipped: 'pid $pid is another process now (started ${row.start})');
          }
          final id = row.identity;
          return (await _end(roots: [id], leaders: [if (id.leadsGroup) id], timings: timings, first: scan)).outcome;
      }
    });
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

  /// Whether [row] may be something a child started that left its tree unseen, environment hidden (macOS platform
  /// binaries): orphaned, this user's, started since [since] (and so during the child's life), not a service, and
  /// not anyone else's child.
  bool _mayHaveEscaped(ScanRow row, DateTime since) {
    if (row.ppid != 1 || row.zombie || row.uid != _Self.it.uid || row.env is! EnvHidden) return false;
    final started = _startedAt(row);
    if (started == null || started.isBefore(since.subtract(const Duration(seconds: 1)))) return false;
    if (started.isAfter(DateTime.now().add(const Duration(seconds: 1)))) return false;
    if (_looksLikeDaemon(row.command)) return false;
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
  /// With [escapedSince] (given only when something left the child's tree unseen), orphans started since then whose
  /// environment is hidden can't be told apart from something the child started: they are not touched, and the
  /// outcome lists them ([Ended.maybeEscaped]).
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
        // Never the app or what it runs under, whatever a ledger or a tag says.
        if (table.alive(r) && !spare.contains(r.pid) && r.pid > 1) {
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
          if (r.pid > 1 && r.pid != pid) targets[r.pid] = r; // blind: the roots as known
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
      // Not the shared scan (2 s apart there): own children by their exit, the rest by tasklist.
      final until = DateTime.now().add(tm.killWait);
      var alive = targets.values.toSet();
      while (true) {
        final still = <ProcessIdentity>{};
        for (final p in alive) {
          if (await _windowsAlive(p.pid, rec)) still.add(p);
        }
        alive = still;
        if (alive.isEmpty || DateTime.now().isAfter(until)) break;
        await Future<void>.delayed(tm.poll);
      }
      return _EndResult(targets.values.toSet(), alive, null, {});
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

  /// Windows: whether [p] still runs. A child of [rec] that the app waits on is asked through its exit future.
  Future<bool> _windowsAlive(int p, _Record? rec) async {
    if (rec != null && rec.pid == p && rec.waitsOnExit) return rec.state.live && !rec._ended.isCompleted;
    final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final r = await _raw('$root\\System32\\tasklist.exe', ['/FI', 'PID eq $p', '/NH', '/FO', 'CSV']);
    return switch (r) {
      _RawDone(:final out) => out.contains('"$p"'),
      _RawFailed() => true, // can't tell: still running as far as anyone knows
    };
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
    bool duringQuit = false,
  }) {
    // In the root zone, whatever the caller's: fake time in widget tests must not drive real timeouts.
    return _inRoot(() async {
      final SupervisedProcess p;
      try {
        p = await _spawn(
          duringQuit: duringQuit,
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
      } on SupervisorClosed catch (e) {
        return Refused(e.what);
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
          return Finished(
            first,
            out.output,
            err.output,
            stdoutEncoding: stdoutEncoding,
            stderrEncoding: stderrEncoding,
          );
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
          ? TimedOut(kill, out.output, err.output, stdoutEncoding: stdoutEncoding, stderrEncoding: stderrEncoding)
          : Cancelled(kill, out.output, err.output, stdoutEncoding: stdoutEncoding, stderrEncoding: stderrEncoding);
    });
  }

  @override
  Future<ProcessScan> scan({bool env = false}) => _inRoot(() => _scanner.get(env: env));

  // ---------------------------------------------------------------- the launch sweep

  @override
  ValueListenable<SweepReport?> get lastSweep => _sweep;

  @override
  Future<SweepReport> sweepPreviousRuns() {
    // In the root zone, whatever the caller's: fake time in widget tests must not drive real timeouts.
    return _inRoot(() {
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
    });
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
    final previous = <LedgerEntry>[];
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
      previous.addAll(ledgerEntriesOf(fold.live));
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
        _previous = List.unmodifiable(previous);
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
    _previous = List.unmodifiable(previous);
    if (!report.quiet) debugPrint('Process supervisor: launch sweep: $report');
    return report;
  }

  // ---------------------------------------------------------------- quitting

  @override
  Future<QuitReport> stopAll({
    StopTimings timings = StopTimings.quit,
    List<Future<void> Function()> before = const [],
  }) {
    // In the root zone, whatever the caller's: fake time in widget tests must not drive real timeouts.
    return _inRoot(() {
      switch (_state) {
        case _SupQuitting(:final done):
          return done;
        case _SupClosed(:final report):
          return Future.value(report);
        case _SupIdle() || _SupOpen():
          final done = _quit(timings, before);
          _state = _SupQuitting(done);
          return done;
        case _SupOpening(done: final opening):
          // The folder being opened is where quit steps' children go.
          final q = opening.then((_) => _quit(timings, before));
          _state = _SupQuitting(q);
          return q;
      }
    });
  }

  Future<QuitReport> _quit(StopTimings timings, List<Future<void> Function()> before) async {
    for (final step in before) {
      try {
        await step();
      } on Object catch (e) {
        debugPrint('Process supervisor: a quit step failed ($e); going on.');
      }
    }
    final entries = <QuitEntry>[];
    final done = <int>{};
    // Again while quit steps still start children (bounded: they are refused once the steps are over).
    for (var round = 0; round < 3; round++) {
      final all = [
        for (final r in _list.values)
          if (!done.contains(r.id)) r,
      ];
      if (all.isEmpty) break;
      final outcomes = await Future.wait([for (final r in all) stop(r, timings: timings)]);
      for (var i = 0; i < all.length; i++) {
        done.add(all[i].id);
        entries.add((id: all[i].id, label: all[i].spec.label, owner: all[i].spec.owner.key, outcome: outcomes[i]));
      }
    }
    final report = QuitReport(entries, at: DateTime.now());
    if (!report.clean) {
      debugPrint(
        'NOT CLOSED at quit: ${[for (final e in report.entries)
          if (e.outcome is! Ended) '${e.label}: ${e.outcome}']}',
      );
    }
    _state = _SupClosed(report); // no quit step may start anything now
    await _files.quit(report, clean: report.clean && _list.isEmpty);
    if (_tick case _TickOn(:final timer)) timer.cancel();
    _tick = const _TickOff();
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
  const _EndResult(this.targets, this.survivors, this.failure, this.maybeEscaped);
  final Set<ProcessIdentity> targets;
  final Set<ProcessIdentity> survivors;

  /// Why the end couldn't be checked (the table couldn't be read).
  final String? failure;

  /// Orphans that may be the child's, environment hidden: untouched, still running.
  final Set<ProcessIdentity> maybeEscaped;

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
    null => Ended(ended, maybeEscaped: [for (final u in maybeEscaped) u.pid]..sort()),
  };
}

// ------------------------------------------------------------------ the ledger files

enum _Flush { idle, scheduled }

/// A folder of the supervisor's own is removed while it holds nothing, and made again for the next line.
enum _Folder { present, removed }

/// The watch list: never written yet, or written (it may list nothing now).
enum _WatchFile { none, written }

/// The ledger file, kept open for appends while it exists.
@immutable
sealed class _LedgerHandle {
  const _LedgerHandle();
}

final class _LedgerClosed extends _LedgerHandle {
  const _LedgerClosed();
}

final class _LedgerOpen extends _LedgerHandle {
  const _LedgerOpen(this.file);
  final RandomAccessFile file;
}

/// The ledger and the watchdog's list, written off the caller's path: ledger lines are queued and appended in
/// batches, the watch list is rewritten (whole, by rename) at most every 30 ms. Files appear with the first line;
/// past [compactAfter] lines the ledger is rewritten as a snapshot of what is listed; once nothing has been listed
/// a folder of the supervisor's own is cleared (see [idle]).
final class _Files {
  _Files(this._sup);
  final _Supervisor _sup;
  String? dir;
  bool removeDirWhenEmpty = false;
  final _pending = StringBuffer();
  var _ledgerFlush = _Flush.idle;
  var _watchFlush = _Flush.idle;
  Future<void> _tail = Future.value();
  var _lines = 0;
  var _idleRound = 0;
  var _folder = _Folder.present;
  var watchState = _WatchFile.none;
  _LedgerHandle _handle = const _LedgerClosed();

  /// Appends [text] through the open handle (opened, with the app line first, when the file is new).
  Future<void> _append(String text) async {
    final RandomAccessFile f;
    switch (_handle) {
      case _LedgerOpen(file: final open):
        f = open;
      case _LedgerClosed():
        final file = File(ledgerPath!);
        final fresh = !await file.exists();
        f = await file.open(mode: FileMode.append);
        _handle = _LedgerOpen(f);
        if (fresh) {
          text = LedgerApp(pid: pid, start: _Self.it.start).encode() + text;
          _lines = 0;
        }
    }
    await f.writeString(text);
    _lines += '\n'.allMatches(text).length;
  }

  Future<void> _closeHandle() async {
    if (_handle case _LedgerOpen(:final file)) {
      _handle = const _LedgerClosed();
      await file.close();
    }
  }

  /// [dir] is made only when something is written there.
  void markFolderAbsent(String dir) {
    if (!Directory(dir).existsSync()) _folder = _Folder.removed;
  }

  Future<void> _ensureFolder() async {
    if (_folder == _Folder.present) return;
    await Directory(dir!).create(recursive: true);
    _folder = _Folder.present;
  }

  static const compactAfter = 2000;

  static String ledgerIn(String dir) => '$dir/ledger-${_Self.it.suffix}.jsonl';
  String? get ledgerPath => dir == null ? null : ledgerIn(dir!);
  String? get watchPath => dir == null ? null : '$dir/watch-${_Self.it.suffix}.list';

  void open(String dir) {
    this.dir = dir;
    final own = File(ledgerIn(dir));
    if (own.existsSync()) _lines = own.readAsLinesSync().length;
    if (_pending.isNotEmpty) _scheduleLedger();
    watchChanged();
  }

  void add(LedgerLine line) {
    _pending.write(line.encode());
    _idleRound++;
    if (dir != null) _scheduleLedger();
  }

  /// [add], on disk when this returns (nothing to wait for before the folder is open).
  Future<void> addNow(LedgerLine line) async {
    add(line);
    if (dir != null) await _tail;
  }

  void _scheduleLedger() {
    if (_ledgerFlush == _Flush.scheduled) return;
    _ledgerFlush = _Flush.scheduled;
    _enqueue(() async {
      _ledgerFlush = _Flush.idle;
      final text = _pending.toString();
      _pending.clear();
      if (text.isEmpty) return;
      await _ensureFolder();
      if (_lines + '\n'.allMatches(text).length > compactAfter) {
        await _compact(File(ledgerPath!));
        return;
      }
      await _append(text);
    });
  }

  /// The ledger rewritten as what is listed now: each child's spawn line, its pid or identity, its tree and
  /// survivors. Ids are kept, so the fold reads the same.
  Future<void> _compact(File f) async {
    final out = StringBuffer(LedgerApp(pid: pid, start: _Self.it.start).encode());
    var n = 1;
    void put(LedgerLine l) {
      out.write(l.encode());
      n++;
    }

    for (final r in _sup._list.values) {
      final spawn = r.spawnLine;
      if (spawn == null) continue;
      put(spawn);
      if (r._port != null || r._detail != null) put(LedgerNote(id: r.id, port: r._port, detail: r._detail));
      switch (r.state) {
        case ChildLaunched(:final pid, :final at, :final group) || ChildUnverified(:final pid, :final at, :final group):
          put(LedgerLaunch(id: r.id, pid: pid, at: at, ownGroup: group is OwnGroup));
        case ChildRunning(:final id) || ChildTerming(:final id) || ChildKilling(:final id):
          put(LedgerRun(id: r.id, identity: id));
        case ChildNotClosed(:final survivors, :final reason):
          put(LedgerNotClosed(id: r.id, survivors: survivors, reason: reason));
        case ChildStarting() || ChildExited() || ChildStartFailed() || ChildDisowned():
          break;
      }
      if (r.tree.isNotEmpty) put(LedgerTree(id: r.id, processes: [...r.tree.values]));
    }
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(out.toString());
    await _closeHandle();
    await tmp.rename(f.path);
    _lines = n;
  }

  void watchChanged() {
    if (dir == null || _watchFlush == _Flush.scheduled) return;
    _watchFlush = _Flush.scheduled;
    Timer(const Duration(milliseconds: 30), () => _enqueue(_writeWatch));
  }

  Future<void> _writeWatch() async {
    _watchFlush = _Flush.idle;
    final live = [for (final r in _sup._list.values) ...r.liveProcesses];
    final path = watchPath!;
    if (live.isEmpty && (_folder == _Folder.removed || !await File(path).exists())) return; // no file needed
    await _ensureFolder();
    final tmp = File('$path.tmp');
    await tmp.writeAsString(watchList(live));
    await tmp.rename(path);
    watchState = _WatchFile.written;
  }

  /// The watch list on disk now (with what was queued before it).
  Future<void> flushWatch() async {
    if (dir == null) return;
    _enqueue(_writeWatch);
    await _tail;
  }

  /// Nothing is listed. A folder of the supervisor's own (tests, a temp one) is cleared at once, after what was
  /// queued, unless something new came meanwhile; the app's folder keeps its ledger (compacted, deleted at a clean
  /// quit). No timer: nothing is left pending (widget tests check).
  void idle() {
    if (!removeDirWhenEmpty || dir == null) return;
    if (_sup._state case _SupQuitting() || _SupClosed()) return;
    final round = ++_idleRound;
    _enqueue(() async {
      if (round != _idleRound || _sup._list.isNotEmpty || _pending.isNotEmpty) return;
      await _closeHandle();
      for (final p in [ledgerPath!, watchPath!]) {
        if (await File(p).exists()) await File(p).delete();
      }
      watchState = _WatchFile.none;
      _lines = 0;
      await _removeDirIfEmpty();
    });
  }

  Future<void> _removeDirIfEmpty() async {
    final d = dir;
    if (!removeDirWhenEmpty || d == null) return;
    final folder = Directory(d);
    if (await folder.exists() && await folder.list().isEmpty) {
      await folder.delete();
      _folder = _Folder.removed;
    }
  }

  void _enqueue(Future<void> Function() op) {
    _tail = _tail.then((_) => op()).catchError((Object e) {
      debugPrint('Process supervisor: the ledger could not be written ($e); a crash now would leave children.');
    });
  }

  /// At quit: `quit.json`, and (everything ended) the ledger and list deleted, after what was queued. A folder of
  /// the supervisor's own keeps nothing when the quit was clean.
  Future<void> quit(QuitReport report, {required bool clean}) async {
    await _tail;
    final d = dir;
    if (d == null) return;
    final done = Completer<void>();
    _enqueue(() async {
      try {
        if (!(clean && removeDirWhenEmpty)) {
          await _ensureFolder();
          await File('$d/quit.json').writeAsString(const JsonEncoder.withIndent('  ').convert(report.toJson()));
        }
        await _closeHandle();
        if (clean) {
          for (final p in [ledgerPath!, watchPath!]) {
            if (await File(p).exists()) await File(p).delete();
          }
          await _removeDirIfEmpty();
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
