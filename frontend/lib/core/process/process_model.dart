// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'child_state.dart';

/// In every child's environment: `<app pid>:<app start token>`, so a process left behind by a crashed run can be
/// told apart (by the next launch's sweep and the watchdog) wherever its environment can be read.
const appEnvVar = 'EVERYAI_APP';

/// In every child's environment: its owner's [ProcessOwner.key].
const ownerEnvVar = 'EVERYAI_OWNER';

/// The session tag shells already carry (see `session_processes.dart`); set for children a session owns.
const sessionTagEnvVar = 'EVERYAI_SESSION';

/// Who a child belongs to: what ends with it.
@immutable
sealed class ProcessOwner {
  const ProcessOwner();

  /// The owner as text (the ledger, [ownerEnvVar]).
  String get key;

  static ProcessOwner parse(String key) => switch (key) {
    'app' => const AppOwner(),
    _ when key.startsWith('session:') => SessionOwner(key.substring(8)),
    _ when key.startsWith('probe:') => ProbeOwner(key.substring(6)),
    _ => ProbeOwner(key),
  };

  @override
  bool operator ==(Object other) => other is ProcessOwner && other.key == key;
  @override
  int get hashCode => key.hashCode;
  @override
  String toString() => key;
}

/// The app itself (browsers, servers, helpers that serve every session).
final class AppOwner extends ProcessOwner {
  const AppOwner();
  @override
  String get key => 'app';
}

final class SessionOwner extends ProcessOwner {
  const SessionOwner(this.id);
  final String id;
  @override
  String get key => 'session:$id';
}

/// A short look at something (a CLI's version, a scan).
final class ProbeOwner extends ProcessOwner {
  const ProbeOwner(this.name);
  final String name;
  @override
  String get key => 'probe:$name';
}

enum ProcessKind {
  leadCli,
  shell,
  pty,
  browser,
  mcp,
  lsp,
  localServer,
  backend,
  helper,
  device,
  script,
  stream,
  display,
  oneShot;

  static ProcessKind parse(String name) => values.firstWhere((k) => k.name == name, orElse: () => helper);
}

// ------------------------------------------------------------------ scans

/// Whether a process's environment could be read, and the EveryAI tags in it.
@immutable
sealed class EnvView {
  const EnvView();
}

final class EnvRead extends EnvView {
  const EnvRead(this.tags);

  /// The `EVERYAI_*` variables set in it.
  final Map<String, String> tags;
}

/// Not readable: another user's process, or (macOS) an Apple platform binary.
final class EnvHidden extends EnvView {
  const EnvHidden();
}

/// One row of a process scan.
@immutable
final class ScanRow {
  const ScanRow({
    required this.pid,
    required this.ppid,
    required this.pgid,
    required this.start,
    required this.command,
    this.uid,
    this.zombie = false,
    this.env = const EnvHidden(),
  });

  final int pid;
  final int ppid;

  /// Its process group; null where there are none (Windows).
  final int? pgid;
  final String start;
  final String command;
  final int? uid;

  /// Ended, waiting for its parent to reap it: counts as gone.
  final bool zombie;
  final EnvView env;

  ProcessIdentity get identity => ProcessIdentity(
    pid: pid,
    start: start,
    group: switch (pgid) {
      null => const NoGroups(),
      final g when g == pid => const OwnGroup(),
      final g => SharedGroup(g),
    },
  );

  String? tag(String name) => switch (env) {
    EnvRead(:final tags) => tags[name],
    EnvHidden() => null,
  };

  ScanRow withEnv(EnvView env) =>
      ScanRow(pid: pid, ppid: ppid, pgid: pgid, start: start, command: command, uid: uid, zombie: zombie, env: env);
}

/// The processes on this machine.
final class ProcessList {
  ProcessList(Iterable<ScanRow> rows) : rows = {for (final r in rows) r.pid: r} {
    for (final r in this.rows.values) {
      if (r.ppid != r.pid) (_children[r.ppid] ??= []).add(r.pid);
    }
  }

  final Map<int, ScanRow> rows;
  final _children = <int, List<int>>{};

  /// Whether [id] (that pid with that start time) is still running (a zombie counts as gone). An identity whose
  /// start is unknown matches its pid alone.
  bool alive(ProcessIdentity id) => switch (rows[id.pid]) {
    final r? => !r.zombie && (!id.startKnown || r.start == id.start),
    null => false,
  };

  bool aliveAt(int pid, String start) => alive(ProcessIdentity(pid: pid, start: start));

  /// Whether [pid] runs and started within a few seconds of [at] (a process recorded before its start time could
  /// be read).
  bool aliveNear(int pid, DateTime at) {
    final r = rows[pid];
    if (r == null || r.zombie) return false;
    final t = lstartTime(r.start);
    return t != null && t.difference(at).inSeconds.abs() <= 3;
  }

  /// Every process below [pid], nearest first.
  List<int> descendants(int pid) {
    final out = <int>[];
    final seen = <int>{pid};
    final queue = [...?_children[pid]];
    while (queue.isNotEmpty) {
      final p = queue.removeAt(0);
      if (!seen.add(p)) continue;
      out.add(p);
      queue.addAll(_children[p] ?? const []);
    }
    return out;
  }

  /// The members of process group [pgid].
  List<int> group(int pgid) => [
    for (final r in rows.values)
      if (r.pgid == pgid) r.pid,
  ];

  /// [pid] and the processes it descends from.
  Set<int> ancestry(int pid) {
    final out = <int>{};
    int? p = pid;
    while (p != null && p > 0 && out.add(p)) {
      p = rows[p]?.ppid;
    }
    return out;
  }
}

/// A scan of the process table: either the table, or why it couldn't be read. Never read a failed scan as "no
/// processes".
@immutable
sealed class ProcessScan {
  const ProcessScan();
}

final class Listed extends ProcessScan {
  const Listed(this.table, {required this.at, this.withEnv = false});
  final ProcessList table;

  /// When it was read.
  final DateTime at;

  /// Whether environments were read too.
  final bool withEnv;
}

// ------------------------------------------------------------------ kills

/// What a stop did, after checking again by pid + start time.
@immutable
sealed class KillOutcome {
  const KillOutcome();

  /// One outcome for several stops: anything that survived wins, then a scan that failed, then processes that
  /// couldn't be accounted for, else what ended.
  static KillOutcome merge(Iterable<KillOutcome> outcomes) {
    final ended = <int>{};
    final survived = <int>{};
    final unaccounted = <int>{};
    final reasons = <String>[];
    final failed = <String>[];
    for (final o in outcomes) {
      switch (o) {
        case Ended(:final pids):
          ended.addAll(pids);
        case Survived(:final pids, :final reason, ended: final e):
          survived.addAll(pids);
          ended.addAll(e);
          if (!reasons.contains(reason)) reasons.add(reason);
        case Unaccounted(:final candidates, :final reason, ended: final e):
          unaccounted.addAll(candidates);
          ended.addAll(e);
          if (!reasons.contains(reason)) reasons.add(reason);
        case ScanFailed(:final why):
          if (!failed.contains(why)) failed.add(why);
      }
    }
    List<int> sorted(Set<int> s) => s.toList()..sort();
    if (survived.isNotEmpty) return Survived(sorted(survived), reasons.join('; '), ended: sorted(ended));
    if (failed.isNotEmpty) return ScanFailed(failed.join('; '));
    if (unaccounted.isNotEmpty) return Unaccounted(sorted(unaccounted), reasons.join('; '), ended: sorted(ended));
    return Ended(sorted(ended));
  }
}

/// Everything it signalled is gone (checked by pid + start time), and nothing it may have started is unaccounted for.
final class Ended extends KillOutcome {
  const Ended(this.pids);

  /// What it ended (empty when nothing was running).
  final List<int> pids;
  @override
  String toString() => 'Ended($pids)';
}

/// These are still running after SIGKILL (or `taskkill /F`).
final class Survived extends KillOutcome {
  const Survived(this.pids, this.reason, {this.ended = const []});
  final List<int> pids;
  final String reason;

  /// What did end.
  final List<int> ended;
  @override
  String toString() => 'Survived($pids: $reason; ended $ended)';
}

/// What it could see ended, but these processes may have been started by the child and left its tree (orphaned
/// while it ran, environment hidden so their tags can't be read): they were not touched, and the end is not proven.
final class Unaccounted extends KillOutcome {
  const Unaccounted(this.candidates, this.reason, {this.ended = const []});
  final List<int> candidates;
  final String reason;
  final List<int> ended;
  @override
  String toString() => 'Unaccounted($candidates: $reason; ended $ended)';
}

/// The process table couldn't be read, so nothing can be said about what is left: never "nothing running". Both a
/// [ProcessScan] (the scan itself) and a [KillOutcome] (a stop that couldn't check its work).
final class ScanFailed extends KillOutcome implements ProcessScan {
  const ScanFailed(this.why);
  final String why;
  @override
  String toString() => 'ScanFailed($why)';
}

// ------------------------------------------------------------------ bounded runs

/// What a bounded run read from one pipe.
@immutable
final class RunOutput {
  const RunOutput(this.bytes, {this.truncated = false});
  final Uint8List bytes;

  /// More was written than `maxOutputBytes`; the rest was read and dropped.
  final bool truncated;

  String text(Encoding encoding) => encoding.decode(bytes);
}

/// How a [runBounded] call ended.
@immutable
sealed class RunResult {
  const RunResult();
}

final class Finished extends RunResult {
  const Finished(
    this.code,
    this.out,
    this.err, {
    this.stdoutEncoding = systemEncodingLike,
    this.stderrEncoding = systemEncodingLike,
    this.leftRunning,
  });
  final int code;
  final RunOutput out;
  final RunOutput err;
  final Encoding stdoutEncoding;
  final Encoding stderrEncoding;

  /// The program exited but something it started still held its pipes; that was stopped, with this outcome.
  final KillOutcome? leftRunning;

  String get stdout => out.text(stdoutEncoding);
  String get stderr => err.text(stderrEncoding);
  Uint8List get stdoutBytes => out.bytes;
  Uint8List get stderrBytes => err.bytes;
  bool get truncated => out.truncated || err.truncated;
  @override
  String toString() => 'Finished($code${leftRunning == null ? '' : ', left running: $leftRunning'})';
}

/// The encoding [Finished] decodes with when none is given (the caller passes `systemEncoding`).
const Encoding systemEncodingLike = utf8;

final class TimedOut extends RunResult {
  const TimedOut(this.kill, this.out, this.err, {this.encoding = systemEncodingLike});
  final KillOutcome kill;

  /// What it wrote before it was stopped.
  final RunOutput out;
  final RunOutput err;
  final Encoding encoding;
  String get stdout => out.text(encoding);
  String get stderr => err.text(encoding);
  @override
  String toString() => 'TimedOut($kill)';
}

final class Cancelled extends RunResult {
  const Cancelled(this.kill, this.out, this.err, {this.encoding = systemEncodingLike});
  final KillOutcome kill;
  final RunOutput out;
  final RunOutput err;
  final Encoding encoding;
  String get stdout => out.text(encoding);
  String get stderr => err.text(encoding);
  @override
  String toString() => 'Cancelled($kill)';
}

final class StartFailed extends RunResult {
  const StartFailed(this.error);
  final String error;
  @override
  String toString() => 'StartFailed($error)';
}

// ------------------------------------------------------------------ sweep and quit reports

/// One process the launch sweep looked at.
typedef SweptProcess = ({int pid, String label, String why});

/// What the launch sweep found from runs that ended without quitting (a crash, Force Quit, a killed test run).
@immutable
final class SweepReport {
  const SweepReport({
    this.ended = const [],
    this.survived = const [],
    this.leftAlone = const [],
    this.ledgers = const [],
    this.failure,
  });

  /// Ended (checked gone).
  final List<SweptProcess> ended;

  /// Still running after SIGKILL; carried into this run's ledger.
  final List<SweptProcess> survived;

  /// Listed in a dead run's ledger but not touched: the pid now belongs to another process (another start time).
  final List<SweptProcess> leftAlone;

  /// The ledgers swept (and deleted).
  final List<String> ledgers;

  /// Why the sweep couldn't run (the process table couldn't be read); null when it ran.
  final String? failure;

  bool get quiet => ended.isEmpty && survived.isEmpty && failure == null;

  @override
  String toString() => 'SweepReport(ended $ended, survived $survived, left alone $leftAlone, failure $failure)';
}

/// What quitting did to each child.
typedef QuitEntry = ({int id, String label, String owner, KillOutcome outcome});

@immutable
final class QuitReport {
  const QuitReport(this.entries, {required this.at});
  final List<QuitEntry> entries;
  final DateTime at;

  bool get clean => entries.every((e) => e.outcome is Ended);

  Map<String, Object?> toJson() => {
    'at': at.toUtc().toIso8601String(),
    'ended': [
      for (final e in entries)
        if (e.outcome case Ended(:final pids)) {'id': e.id, 'label': e.label, 'owner': e.owner, 'pids': pids},
    ],
    'survived': [
      for (final e in entries)
        if (e.outcome case Survived(:final pids, :final reason))
          {'id': e.id, 'label': e.label, 'owner': e.owner, 'pids': pids, 'reason': reason},
    ],
    'unaccounted': [
      for (final e in entries)
        if (e.outcome case Unaccounted(:final candidates, :final reason))
          {'id': e.id, 'label': e.label, 'owner': e.owner, 'pids': candidates, 'reason': reason},
    ],
    'scanFailed': [
      for (final e in entries)
        if (e.outcome case ScanFailed(:final why)) {'id': e.id, 'label': e.label, 'owner': e.owner, 'why': why},
    ],
  };
}

// ------------------------------------------------------------------ parsing

/// A start time as `ps -o lstart=` prints it, made into one token (each run of whitespace becomes `_`), as the
/// watchdog script makes it too.
String startToken(String lstart) => lstart.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).join('_');

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// The local time a [startToken] names (`Thu_Nov_12_01:50:25_2026`), or null when it isn't one.
DateTime? lstartTime(String token) {
  final p = token.split('_');
  if (p.length != 5) return null;
  final month = _months.indexOf(p[1]) + 1;
  final day = int.tryParse(p[2]), year = int.tryParse(p[4]);
  final hms = p[3].split(':').map(int.tryParse).toList();
  if (month == 0 || day == null || year == null || hms.length != 3 || hms.contains(null)) return null;
  return DateTime(year, month, day, hms[0]!, hms[1]!, hms[2]!);
}

/// The value of [appEnvVar] for app [pid] that started at [start].
String appTag(int pid, String start) => '$pid:$start';

/// The pid and start token in an [appEnvVar] value, or null when it isn't one.
({int pid, String start})? parseAppTag(String tag) {
  final i = tag.indexOf(':');
  if (i <= 0) return null;
  final pid = int.tryParse(tag.substring(0, i));
  return pid == null ? null : (pid: pid, start: tag.substring(i + 1));
}

final _psLine = RegExp(r'^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(\S+\s+\S+\s+\S+\s+\S+\s+\S+)\s?(.*)$');

/// Rows of `ps -A -ww -o pid=,ppid=,pgid=,uid=,stat=,lstart=,command=` (macOS, Linux) under `LC_ALL=C`. Lines
/// that don't parse are left out; a listing with none that parses is a failed scan (the caller decides).
List<ScanRow> parsePsRows(String out) => [
  for (final line in const LineSplitter().convert(out))
    if (_psLine.firstMatch(line) case final m?)
      ScanRow(
        pid: int.parse(m.group(1)!),
        ppid: int.parse(m.group(2)!),
        pgid: int.parse(m.group(3)!),
        uid: int.parse(m.group(4)!),
        zombie: m.group(5)!.startsWith('Z'),
        start: startToken(m.group(6)!),
        command: m.group(7)!.trim(),
      ),
];

final _envTag = RegExp(r'(?:^|\s)(EVERYAI_[A-Z_]+)=(\S*)');

/// The `EVERYAI_*` tags of each pid from `ps -E -A -ww -o pid=,command=` (macOS), given the same listing without
/// `-E` ([plain]): the environment follows the arguments, and a line that didn't get longer had none readable.
Map<int, EnvView> parsePsEnv(String withEnv, String plain) {
  final line = RegExp(r'^\s*(\d+)\s(.*)$');
  final commands = <int, String>{};
  for (final l in const LineSplitter().convert(plain)) {
    if (line.firstMatch(l) case final m?) commands[int.parse(m.group(1)!)] = m.group(2)!;
  }
  final out = <int, EnvView>{};
  for (final l in const LineSplitter().convert(withEnv)) {
    final m = line.firstMatch(l);
    if (m == null) continue;
    final pid = int.parse(m.group(1)!);
    final cmd = commands[pid];
    final rest = m.group(2)!;
    if (cmd == null || rest.length <= cmd.length || !rest.startsWith(cmd)) {
      out[pid] = const EnvHidden();
      continue;
    }
    out[pid] = EnvRead({for (final t in _envTag.allMatches(rest.substring(cmd.length))) t.group(1)!: t.group(2)!});
  }
  return out;
}

/// The `EVERYAI_*` tags in a NUL-separated environment block (`/proc/<pid>/environ`).
Map<String, String> envTagsOf(String environ) => {
  for (final e in environ.split('\x00'))
    if (e.startsWith('EVERYAI_') && e.contains('=')) e.substring(0, e.indexOf('=')): e.substring(e.indexOf('=') + 1),
};

// ------------------------------------------------------------------ the ledger

/// One line of a run's ledger (`processes/ledger-<app pid>-<app start token>.jsonl`): what this run started and
/// what became of it.
@immutable
sealed class LedgerLine {
  const LedgerLine();

  Map<String, Object?> toJson();

  String encode() => '${jsonEncode(toJson())}\n';

  static LedgerLine? decode(String line) {
    final Object? j;
    try {
      j = jsonDecode(line);
    } on FormatException {
      return null; // a line cut off by a crash
    }
    if (j is! Map<String, Object?>) return null;
    List<ProcessIdentity> ids(Object? list) => [
      if (list is List)
        for (final x in list) ?ProcessIdentity.fromJson(x),
    ];
    return switch (j) {
      {'t': 'app', 'pid': final int pid, 'start': final String start} => LedgerApp(pid: pid, start: start),
      {
        't': 'spawn',
        'id': final int id,
        'exe': final String exe,
        'owner': final String owner,
        'kind': final String kind,
        'label': final String label,
      } =>
        LedgerSpawn(
          id: id,
          exe: exe,
          owner: owner,
          kind: kind,
          label: label,
          outlivesApp: j['outlives'] == true,
          port: j['port'] is int ? j['port'] as int : null,
          detail: j['detail'] is String ? j['detail'] as String : null,
        ),
      {'t': 'launch', 'id': final int id, 'pid': final int pid, 'at': final int at} => LedgerLaunch(
        id: id,
        pid: pid,
        at: DateTime.fromMillisecondsSinceEpoch(at),
        ownGroup: j['own'] != false,
      ),
      {'t': 'run', 'id': final int id} => switch (ProcessIdentity.fromJson(j)) {
        final ident? => LedgerRun(id: id, identity: ident),
        null => null,
      },
      {'t': 'tree', 'id': final int id} => LedgerTree(id: id, processes: ids(j['procs'])),
      {'t': 'state', 'id': final int id, 'state': final String state} => LedgerState(id: id, state: state),
      {'t': 'exit', 'id': final int id} => LedgerExit(id: id, code: j['code'] is int ? j['code'] as int : null),
      {'t': 'notClosed', 'id': final int id, 'reason': final String reason} => LedgerNotClosed(
        id: id,
        survivors: ids(j['survivors']),
        reason: reason,
      ),
      _ => null,
    };
  }
}

/// The first line: whose ledger this is.
final class LedgerApp extends LedgerLine {
  const LedgerApp({required this.pid, required this.start});
  final int pid;
  final String start;
  @override
  Map<String, Object?> toJson() => {'t': 'app', 'pid': pid, 'start': start};
}

/// Written before the process is started, so a crash right after leaves a trace.
final class LedgerSpawn extends LedgerLine {
  const LedgerSpawn({
    required this.id,
    required this.exe,
    required this.owner,
    required this.kind,
    required this.label,
    this.outlivesApp = false,
    this.port,
    this.detail,
  });
  final int id;
  final String exe;
  final String owner;
  final String kind;
  final String label;

  /// Started to outlive the app on purpose (an editor, a file reveal, the updater's restart): never swept.
  final bool outlivesApp;
  final int? port;
  final String? detail;
  @override
  Map<String, Object?> toJson() => {
    't': 'spawn',
    'id': id,
    'exe': exe,
    'owner': owner,
    'kind': kind,
    'label': label,
    if (outlivesApp) 'outlives': true,
    'port': ?port,
    'detail': ?detail,
  };
}

/// Its pid, at once (before its start time is read).
final class LedgerLaunch extends LedgerLine {
  const LedgerLaunch({required this.id, required this.pid, required this.at, this.ownGroup = true});
  final int id;
  final int pid;
  final DateTime at;
  final bool ownGroup;
  @override
  Map<String, Object?> toJson() => {
    't': 'launch',
    'id': id,
    'pid': pid,
    'at': at.millisecondsSinceEpoch,
    if (!ownGroup) 'own': false,
  };
}

/// Its pid, group and start time.
final class LedgerRun extends LedgerLine {
  const LedgerRun({required this.id, required this.identity});
  final int id;
  final ProcessIdentity identity;
  @override
  Map<String, Object?> toJson() => {'t': 'run', 'id': id, ...identity.toJson()};
}

/// What runs below it (or ran below it and left), as last seen.
final class LedgerTree extends LedgerLine {
  const LedgerTree({required this.id, required this.processes});
  final int id;
  final List<ProcessIdentity> processes;
  @override
  Map<String, Object?> toJson() => {
    't': 'tree',
    'id': id,
    'procs': [for (final p in processes) p.toJson()],
  };
}

final class LedgerState extends LedgerLine {
  const LedgerState({required this.id, required this.state});
  final int id;
  final String state;
  @override
  Map<String, Object?> toJson() => {'t': 'state', 'id': id, 'state': state};
}

final class LedgerExit extends LedgerLine {
  const LedgerExit({required this.id, required this.code});
  final int id;
  final int? code;
  @override
  Map<String, Object?> toJson() => {'t': 'exit', 'id': id, 'code': ?code};
}

final class LedgerNotClosed extends LedgerLine {
  const LedgerNotClosed({required this.id, required this.survivors, required this.reason});
  final int id;
  final List<ProcessIdentity> survivors;
  final String reason;
  @override
  Map<String, Object?> toJson() => {
    't': 'notClosed',
    'id': id,
    'survivors': [for (final s in survivors) s.toJson()],
    'reason': reason,
  };
}

/// A process a ledger names: by pid + start time, or (recorded before its start time was read) by pid and when it
/// was started.
typedef LedgerProcess = ({ProcessIdentity id, DateTime? at});

/// What a ledger says is still running, by child: the child and what its tree held.
typedef LedgerLive = ({int id, String label, String owner, List<LedgerProcess> processes});

/// A ledger read back. Ids are this ledger's own (one run each); never mix two ledgers' ids.
@immutable
final class LedgerFold {
  const LedgerFold({required this.app, required this.live, required this.lastId});

  /// Whose ledger (null when its first line is missing or cut off).
  final LedgerApp? app;
  final List<LedgerLive> live;

  /// The highest child id in it (a reopened run goes on from there).
  final int lastId;

  static LedgerFold of(Iterable<String> lines) {
    LedgerApp? app;
    var lastId = 0;
    final spawns = <int, LedgerSpawn>{};
    final self = <int, LedgerProcess>{};
    final trees = <int, List<ProcessIdentity>>{};
    final order = <int>[];
    void see(int id) {
      if (!order.contains(id)) order.add(id);
      if (id > lastId) lastId = id;
    }

    for (final l in lines) {
      if (l.trim().isEmpty) continue;
      switch (LedgerLine.decode(l)) {
        case final LedgerApp a:
          app ??= a;
        case final LedgerSpawn s:
          spawns[s.id] = s;
          see(s.id);
        case LedgerLaunch(:final id, :final pid, :final at, :final ownGroup):
          see(id);
          self[id] = (
            id: ProcessIdentity(pid: pid, start: unknownStart, group: ownGroup ? const OwnGroup() : SharedGroup(0)),
            at: at,
          );
        case LedgerRun(:final id, :final identity):
          see(id);
          self[id] = (id: identity, at: null);
        case LedgerTree(:final id, :final processes):
          trees[id] = processes;
        case LedgerExit(:final id):
          self.remove(id);
        case LedgerNotClosed(:final id, :final survivors):
          see(id);
          self.remove(id);
          trees[id] = [...?trees[id], ...survivors];
        case LedgerState() || null:
          break;
      }
    }
    return LedgerFold(
      app: app,
      lastId: lastId,
      live: [
        for (final id in order)
          if (!(spawns[id]?.outlivesApp ?? false))
            if ([?self[id], for (final t in trees[id] ?? const <ProcessIdentity>[]) (id: t, at: null)] case final p
                when p.isNotEmpty)
              (id: id, label: spawns[id]?.label ?? '?', owner: spawns[id]?.owner ?? 'app', processes: p),
      ],
    );
  }
}

/// The watchdog's list: one `<pgid or -> <pid> <start token or ~epoch>` line per process. The group is given only
/// for a process that leads its own group; `~<epoch seconds>` names a process by when it was started (its start
/// time wasn't read yet).
String watchList(Iterable<LedgerProcess> live) => [
  for (final p in live)
    '${p.id.leadsGroup ? p.id.pid : '-'} ${p.id.pid} '
        '${p.id.startKnown ? p.id.start : '~${(p.at ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000}'}\n',
].join();
