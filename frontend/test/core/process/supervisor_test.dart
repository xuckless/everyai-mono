// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:every_ai/core/process/supervisor.dart';
import 'package:every_ai/core/process/supervisor_io.dart' show watchdogScript;
import 'package:flutter_test/flutter_test.dart';

// Every process these tests start carries [marker] (a shell's $0, a script's name) or sleeps [nap] seconds, so the
// tearDown can tell whether any was left behind.
final marker = 'everyai-sup-test-$pid';
final nap = '30.$pid';

const fast = StopTimings(
  termGrace: Duration(milliseconds: 400),
  killWait: Duration(seconds: 2),
  poll: Duration(milliseconds: 25),
);

String _ps(List<String> args) => '${Process.runSync('ps', args, environment: const {'LC_ALL': 'C'}).stdout}'.trim();

int pgidOf(int p) => int.parse(_ps(['-o', 'pgid=', '-p', '$p']));
String startOf(int p) => startToken(_ps(['-o', 'lstart=', '-p', '$p']));
bool running(int p) {
  final stat = _ps(['-o', 'stat=', '-p', '$p']);
  return stat.isNotEmpty && !stat.startsWith('Z');
}

/// Processes of these tests still running (not this test process itself).
List<String> leftovers() => [
  for (final l in const LineSplitter().convert(_ps(['-A', '-ww', '-o', 'pid=,stat=,command='])))
    if ((l.contains(marker) || l.contains(' $nap')) && !l.contains(' ps ') && !l.contains('Z')) l.trim(),
];

Future<void> eventually(bool Function() ok, {Duration within = const Duration(seconds: 5)}) async {
  final until = DateTime.now().add(within);
  while (!ok()) {
    if (DateTime.now().isAfter(until)) fail('timed out waiting');
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void main() {
  late Directory dir;
  final made = <ProcessSupervisor>[];

  ProcessSupervisor supervisor({SupervisorHooks hooks = const SupervisorHooks(timings: fast)}) {
    final s = ProcessSupervisor.create(hooks: hooks, ledgerDir: '${dir.path}/l${made.length}');
    made.add(s);
    return s;
  }

  SpawnSpec sh(String script, {ProcessOwner owner = const AppOwner()}) =>
      SpawnSpec(owner: owner, kind: ProcessKind.shell, exe: '/bin/sh', args: ['-c', script, marker], label: 'sh');

  setUp(() {
    dir = Directory.systemTemp.createTempSync('supervisor');
    assertOnRefusedChildTransition = true;
  });

  tearDown(() async {
    for (final s in made) {
      await s.stopAll();
    }
    made.clear();
    final left = leftovers();
    for (final l in left) {
      Process.killPid(int.parse(l.split(RegExp(r'\s+')).first), ProcessSignal.sigkill);
    }
    dir.deleteSync(recursive: true);
    expect(left, isEmpty, reason: 'processes left behind');
  });

  group('the state table', () {
    final id = const ProcessIdentity(pid: 10, pgid: 10, start: 's');
    final at = DateTime(2026);
    ChildState step(ChildState s, ChildChange e) => switch (nextChildState(s, e)) {
      ChildMoves(:final next) => next,
      ChildStays() => s,
      ChildRefused() => throw StateError('refused'),
    };
    bool refused(ChildState s, ChildChange e) => nextChildState(s, e) is ChildRefused;

    test('the edges of the diagram', () {
      var s = step(const ChildStarting(), ChildLanded(id, at));
      expect(s, ChildRunning(id, at));
      s = step(s, ChildTermSent(at));
      expect(s, isA<ChildTerming>());
      expect(step(s, ChildTermSent(at)), s, reason: 'a second TERM joins');
      s = step(s, ChildKillSent(at));
      expect(s, isA<ChildKilling>());
      s = step(s, const ChildExitSeen(ExitCode(-9)));
      expect(s, const ChildExited(ExitCode(-9)));
      expect(step(s, const ChildExitSeen(SeenGone())), s, reason: 'the exit future after a scan saw it gone');
      expect(step(s, ChildSurvivors([id], 'left')), isA<ChildNotClosed>(), reason: 'its group left processes');
      final nc = step(ChildKilling(id, at), ChildSurvivors([id], 'x'));
      expect(nc, ChildNotClosed([id], 'x'));
      expect(step(nc, ChildTermSent(at)), ChildTerming(id, at), reason: 'a retry');
      expect(step(nc, const ChildExitSeen(SeenGone())), const ChildExited(SeenGone()));
      expect(step(const ChildStarting(), const ChildExitSeen(ExitCode(0))), const ChildExited(ExitCode(0)));
      expect(step(const ChildStarting(), const ChildFailedToStart('no')), const ChildStartFailed('no'));
      expect(step(ChildRunning(id, at), ChildKillSent(at)), ChildKilling(id, at));
    });

    test('refused edges: recorded, and the state stays', () {
      expect(refused(const ChildStarting(), ChildTermSent(at)), isTrue, reason: 'a stop waits for the landing');
      expect(refused(const ChildStarting(), ChildSurvivors([id], 'x')), isTrue);
      expect(refused(ChildRunning(id, at), ChildLanded(id, at)), isTrue);
      expect(refused(ChildRunning(id, at), ChildSurvivors([id], 'x')), isTrue, reason: 'survivors only after a stop');
      expect(refused(const ChildExited(SeenGone()), ChildLanded(id, at)), isTrue);
      for (final e in [ChildLanded(id, at), ChildTermSent(at), const ChildExitSeen(SeenGone())]) {
        expect(refused(const ChildStartFailed('x'), e), isTrue);
      }
      assertOnRefusedChildTransition = false;
      refusedChildTransitions.clear();
      final s = applyChildEvent(const ChildExited(SeenGone()), ChildLanded(id, at), label: 't');
      expect(s, const ChildExited(SeenGone()));
      expect(refusedChildTransitions.single.label, 't');
      assertOnRefusedChildTransition = true;
    });
  });

  group('processes', () {
    test('a child leads a process group of its own and carries the app and owner tags', () async {
      final s = supervisor();
      final p = await s.spawn(
        SpawnSpec(owner: const SessionOwner('s1'), kind: ProcessKind.helper, exe: 'sleep', args: [nap]),
      );
      final id = await p.landed;
      expect(id.pid, p.pid);
      expect(pgidOf(id.pid), id.pid, reason: 'its own group');
      expect(id.pgid, id.pid);
      expect(pgidOf(id.pid), isNot(pgidOf(pid)), reason: 'not the app\'s group');
      expect(id.start, startOf(id.pid));

      final r = await s.runBounded(
        '/bin/sh',
        ['-c', r'echo "$EVERYAI_APP|$EVERYAI_OWNER|$EVERYAI_SESSION"; echo "$$ $(ps -o pgid= -p $$)"', marker],
        owner: const SessionOwner('s1'),
        timeout: const Duration(seconds: 10),
      );
      expect(r, isA<Finished>());
      final lines = const LineSplitter().convert((r as Finished).stdout);
      expect(lines.first, '${s.appTag}|session:s1|s1');
      expect(s.appTag, '$pid:${startOf(pid)}');
      final [shPid, shPgid] = lines[1].trim().split(RegExp(r'\s+'));
      expect(shPgid, shPid, reason: 'a one-shot leads its own group too');

      expect(await p.stop(), isA<Ended>());
      expect(p.state, isA<ChildExited>());
      expect(running(id.pid), isFalse);
    });

    test('a child that ignores TERM, with a grandchild: the stop goes through Killing and ends both', () async {
      final s = supervisor();
      final p = await s.spawn(sh('trap "" TERM; sleep $nap & wait; sleep $nap'));
      final states = <ChildState>[];
      p.states.listen(states.add);
      final id = await p.landed;
      late int grandchild;
      await eventually(() {
        final kids = _ps(['-A', '-o', 'pid=,ppid=']).split('\n').map((l) => l.trim().split(RegExp(r'\s+')));
        final k = kids.where((k) => k.length == 2 && k[1] == '${id.pid}').toList();
        if (k.isEmpty) return false;
        grandchild = int.parse(k.first[0]);
        return true;
      });
      final out = await p.stop();
      expect(out, isA<Ended>());
      expect((out as Ended).pids, containsAll([id.pid, grandchild]));
      expect(states.map((x) => x.name), containsAllInOrder(['terming', 'killing', 'exited']));
      expect(running(id.pid), isFalse);
      expect(running(grandchild), isFalse);
      expect(s.children, isEmpty);
    });

    test('a second stop joins the first; TERM goes out once', () async {
      final terms = <int>[];
      final s = supervisor(
        hooks: SupervisorHooks(
          timings: fast,
          signal: (p, sig) {
            if (sig == ProcessSignal.sigterm) terms.add(p);
            return Process.killPid(p, sig);
          },
        ),
      );
      final p = await s.spawn(SpawnSpec(owner: const AppOwner(), kind: ProcessKind.helper, exe: 'sleep', args: [nap]));
      final id = await p.landed;
      final a = p.stop(), b = s.stop(p);
      expect(identical(a, b), isTrue);
      await a;
      expect(terms.where((t) => t == id.pid), hasLength(1));
      expect(terms.where((t) => t == -id.pgid), hasLength(1));
    });

    test('a stop of a child still starting ends it once it lands', () async {
      final s = supervisor();
      final spawned = s.spawn(SpawnSpec(owner: const AppOwner(), kind: ProcessKind.helper, exe: 'sleep', args: [nap]));
      expect(s.children.single.state, const ChildStarting());
      final quit = await s.stopAll();
      final p = await spawned;
      expect(quit.entries.single.outcome, isA<Ended>());
      expect(p.state, isA<ChildExited>());
      expect(running(p.pid!), isFalse);
    });

    test('stopOwner ends an orphan that left the group, found by its owner tag', () async {
      // The orphan must show its environment: Linux shows every process's, macOS hides system binaries' (so the
      // Dart VM stands in for a user's program there).
      String exe;
      List<String> args;
      if (Platform.isMacOS) {
        final cache = Platform.resolvedExecutable.indexOf('/bin/cache/');
        expect(cache, greaterThan(0), reason: 'the Dart SDK next to the test runner');
        exe = '${Platform.resolvedExecutable.substring(0, cache)}/bin/cache/dart-sdk/bin/dart';
        final script = File('${dir.path}/$marker-orphan.dart')
          ..writeAsStringSync('Future<void> main() => Future<void>.delayed(const Duration(seconds: 30));\n');
        args = [script.path];
      } else {
        exe = 'sleep';
        args = [nap];
      }
      final s = supervisor();
      const owner = SessionOwner('orphans');
      final r = await s.runBounded(
        '/bin/bash',
        ['-c', r'set -m; nohup "$@" >/dev/null 2>&1 & echo $!; exit 0', marker, exe, ...args],
        owner: owner,
        timeout: const Duration(seconds: 10),
      );
      final orphan = int.parse((r as Finished).stdout.trim());
      await eventually(() => _ps(['-o', 'ppid=', '-p', '$orphan']) == '1');
      expect(pgidOf(orphan), isNot(pgidOf(pid)));
      expect(running(orphan), isTrue);
      final out = await s.stopOwner(owner);
      expect(out, isA<Ended>());
      expect((out as Ended).pids, contains(orphan));
      expect(running(orphan), isFalse);
    });

    test('a failed scan is never "nothing left": ScanFailed, and the child is not Exited', () async {
      var failing = false;
      final s = supervisor(
        hooks: SupervisorHooks(
          timings: const StopTimings(termGrace: Duration(milliseconds: 100), killWait: Duration(milliseconds: 100)),
          scan: ({required env}) async => failing ? const ScanFailed('injected') : s0.scan(env: env),
          signal: (_, _) => true, // signals "sent" but nothing happens
        ),
      );
      final p = await s.spawn(SpawnSpec(owner: const AppOwner(), kind: ProcessKind.helper, exe: 'sleep', args: [nap]));
      final id = await p.landed;
      failing = true;
      final out = await p.stop();
      expect(out, isA<ScanFailed>());
      expect(p.state, isA<ChildNotClosed>());
      expect(s.children, contains(p));
      expect(running(id.pid), isTrue);
      Process.killPid(id.pid, ProcessSignal.sigkill);
      expect(await p.exitCode, isNot(0));
      expect(p.state, isA<ChildExited>(), reason: 'its own exit future');
    });

    test('an unkillable child is NotClosed, stays listed, and is seen gone once it is', () async {
      final s = supervisor(
        hooks: const SupervisorHooks(
          timings: StopTimings(termGrace: Duration(milliseconds: 100), killWait: Duration(milliseconds: 200)),
          signal: _ignore,
        ),
      );
      final p = await s.spawn(SpawnSpec(owner: const AppOwner(), kind: ProcessKind.helper, exe: 'sleep', args: [nap]));
      final id = await p.landed;
      final out = await p.stop();
      expect(out, isA<Survived>());
      expect((out as Survived).pids, [id.pid]);
      expect(p.state, ChildNotClosed([id], 'still running after SIGKILL'));
      expect(s.children, contains(p));
      expect(s.byPid(id.pid), same(p));
      Process.killPid(id.pid, ProcessSignal.sigkill);
      await p.ended.timeout(const Duration(seconds: 5));
      expect(p.state, isA<ChildExited>());
      expect(s.children, isEmpty);
    });

    test('killTree ends a process the supervisor did not start, with its tree', () async {
      final s = supervisor();
      final raw = await Process.start('/bin/sh', ['-c', 'sleep $nap & wait', marker]);
      await eventually(() => _ps(['-A', '-o', 'ppid=']).split('\n').any((l) => l.trim() == '${raw.pid}'));
      final out = await s.killTree(raw.pid, termWait: const Duration(milliseconds: 300));
      expect(out, isA<Ended>());
      expect((out as Ended).pids, hasLength(2));
      await raw.exitCode;
    });
  });

  group('runBounded', () {
    test('finishes with code and output; stdin goes in', () async {
      final r = await supervisor().runBounded(
        '/bin/sh',
        ['-c', r'read x; echo "got $x"; echo err >&2; exit 3', marker],
        stdin: 'hi\n',
        timeout: const Duration(seconds: 10),
      );
      expect(r, isA<Finished>());
      final f = r as Finished;
      expect((f.code, f.stdout, f.stderr), (3, 'got hi\n', 'err\n'));
    });

    test('a program that is not there is StartFailed', () async {
      final r = await supervisor().runBounded('no-such-program-$pid', const [], timeout: const Duration(seconds: 5));
      expect(r, isA<StartFailed>());
    });

    test('a timeout kills the command and its child, verified', () async {
      final s = supervisor();
      final r = await s.runBounded('/bin/sh', [
        '-c',
        'sleep $nap & sleep $nap',
        marker,
      ], timeout: const Duration(milliseconds: 400));
      expect(r, isA<TimedOut>());
      final kill = (r as TimedOut).kill;
      expect(kill, isA<Ended>());
      expect((kill as Ended).pids.length, greaterThanOrEqualTo(3));
      expect(leftovers(), isEmpty);
    });

    test('what a finished command left running in its group is listed, and ended with the rest', () async {
      final s = supervisor();
      final r = await s.runBounded('/bin/sh', [
        '-c',
        'sleep $nap >/dev/null 2>&1 &',
        marker,
      ], timeout: const Duration(seconds: 10));
      expect(r, isA<Finished>());
      await eventually(() => s.children.any((c) => c.spec.label.endsWith('(left running)')));
      final left = s.children.single;
      expect(running(left.pid!), isTrue);
      final quit = await s.stopAll();
      expect(quit.entries.single.outcome, isA<Ended>());
      expect(running(left.pid!), isFalse);
    });

    test('a cancel stops it', () async {
      final cancel = Completer<void>();
      final r = supervisor().runBounded('sleep', [nap], timeout: const Duration(seconds: 30), cancel: cancel.future);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      cancel.complete();
      final res = await r;
      expect(res, isA<Cancelled>());
      expect((res as Cancelled).kill, isA<Ended>());
    });
  });

  group('ledger, sweep, watchdog, quit', () {
    test(
      'the ledger records spawn, run, states and exit; stopAll writes quit.json and deletes a clean ledger',
      () async {
        final s = supervisor();
        final p = await s.spawn(
          SpawnSpec(owner: const AppOwner(), kind: ProcessKind.helper, exe: 'sleep', args: [nap]),
        );
        await p.landed;
        final ledger = File('${await s.ledgerDirectory}/ledger-$pid.jsonl');
        await p.stop();
        final lines = ledger.readAsLinesSync().map(LedgerLine.decode).toList();
        expect(lines.first, isA<LedgerApp>());
        expect(lines.whereType<LedgerSpawn>().single.label, 'sleep');
        expect(lines.whereType<LedgerRun>().single.identity.pid, p.pid);
        expect(lines.whereType<LedgerState>().map((l) => l.state), contains('terming'));
        expect(lines.whereType<LedgerExit>(), hasLength(1));
        expect(LedgerFold.of(ledger.readAsLinesSync()).live, isEmpty);

        final q = await s.stopAll();
        expect(q.clean, isTrue);
        expect(File('${await s.ledgerDirectory}/quit.json').existsSync(), isTrue);
        expect(ledger.existsSync(), isFalse);
      },
    );

    test('a supervisor that sweeps at start does so once, on its first use, and keeps the report', () async {
      final s = ProcessSupervisor.create(
        hooks: const SupervisorHooks(timings: fast),
        ledgerDir: '${dir.path}/app',
        sweepAtStart: true,
      );
      made.add(s);
      expect(s.lastSweep.value, isNull);
      final raw = await Process.start('sleep', [nap]);
      final c = s.adopt(
        raw.pid,
        const SpawnSpec(owner: AppOwner(), kind: ProcessKind.helper, exe: 'sleep'),
        exitCode: raw.exitCode,
      );
      await c.landed;
      await eventually(() => s.lastSweep.value != null);
      expect(s.lastSweep.value!.failure, isNull);
      expect(identical(s.sweepPreviousRuns(), s.sweepPreviousRuns()), isTrue);
      expect(await c.stop(), isA<Ended>());
    });

    test('the sweep ends what a dead run listed, only where pid and start time both match', () async {
      final helper = supervisor();
      SpawnSpec napSpec() => SpawnSpec(owner: const AppOwner(), kind: ProcessKind.helper, exe: 'sleep', args: [nap]);
      final ours = await helper.spawn(napSpec());
      final reused = await helper.spawn(napSpec());
      final a = await ours.landed, b = await reused.landed;
      // A run that has ended: a pid that is gone.
      final gone = await Process.start('true', const []);
      await gone.exitCode;
      final s = supervisor();
      final ledgerDir = await s.ledgerDirectory;
      final dead = File('$ledgerDir/ledger-${gone.pid}.jsonl')
        ..writeAsStringSync(
          [
            LedgerApp(pid: gone.pid, start: 'Thu_Jan_1_00:00:00_1970', pgid: gone.pid),
            const LedgerSpawn(id: 1, exe: 'sleep', owner: 'app', kind: 'helper', label: 'ours'),
            LedgerRun(id: 1, identity: a),
            const LedgerSpawn(id: 2, exe: 'sleep', owner: 'app', kind: 'helper', label: 'reused'),
            LedgerRun(
              id: 2,
              identity: ProcessIdentity(pid: b.pid, pgid: b.pgid, start: 'Mon_Jan_1_00:00:00_2001'),
            ),
          ].map((l) => l.encode()).join(),
        );
      final report = await s.sweepPreviousRuns();
      expect(report.failure, isNull);
      expect(report.ended.map((e) => e.pid), [a.pid]);
      expect(report.leftAlone.map((e) => e.pid), [b.pid]);
      expect(report.survived, isEmpty);
      expect(s.lastSweep.value, same(report));
      expect(dead.existsSync(), isFalse);
      expect(running(a.pid), isFalse);
      expect(running(b.pid), isTrue, reason: 'another start time: not ours');
    });

    test('the watchdog ends a listed group once the app dies, and leaves a pid with another start time', () async {
      final s = supervisor();
      final group = await s.spawn(sh('sleep $nap & wait'));
      final stranger = await s.spawn(
        SpawnSpec(owner: const AppOwner(), kind: ProcessKind.helper, exe: 'sleep', args: [nap]),
      );
      final g = await group.landed, st = await stranger.landed;
      await eventually(() => _ps(['-A', '-o', 'pgid=']).split('\n').where((l) => l.trim() == '${g.pgid}').length == 2);
      // A stand-in app that dies in a second (not the test runner).
      final app = await Process.start('sleep', ['1']);
      final appStart = startOf(app.pid);
      final list = File('${dir.path}/watch.list')
        ..writeAsStringSync(
          watchList([
            g,
            ProcessIdentity(pid: st.pid, pgid: st.pgid, start: 'Mon_Jan_1_00:00:00_2001'),
          ], appPgid: pgidOf(pid)),
        );
      final run = await Process.run('/bin/sh', [
        '-c',
        watchdogScript,
        'everyai-watchdog',
        '${app.pid}',
        appStart,
        list.path,
        'nobody:none',
        '0.2',
        '0.3',
      ]);
      expect(run.exitCode, 0, reason: '${run.stderr}');
      expect(await app.exitCode, 0);
      await group.ended.timeout(const Duration(seconds: 5));
      expect(_ps(['-A', '-o', 'pgid=']).split('\n').where((l) => l.trim() == '${g.pgid}'), isEmpty);
      expect(running(st.pid), isTrue);
      expect(list.existsSync(), isFalse);
    });
  });
}

/// Real scans, for hooks that fail on purpose later.
final s0 = ProcessSupervisor.create(hooks: const SupervisorHooks());

bool _ignore(int pid, ProcessSignal signal) => true;
