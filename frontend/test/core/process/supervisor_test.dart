// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:every_ai/core/process/supervisor.dart';
import 'package:every_ai/core/process/supervisor_io.dart' show childEnvVar, watchdogScript;
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

/// The pids of `sleep <nap>` processes whose parent is init.
List<int> orphanNaps() => [
  for (final l in const LineSplitter().convert(_ps(['-A', '-ww', '-o', 'pid=,ppid=,command='])))
    if (RegExp(r'^\s*(\d+)\s+1\s+sleep ' + RegExp.escape(nap) + r'$').firstMatch(l) case final m?)
      int.parse(m.group(1)!),
];

Future<void> eventually(bool Function() ok, {Duration within = const Duration(seconds: 5)}) async {
  final until = DateTime.now().add(within);
  while (!ok()) {
    if (DateTime.now().isAfter(until)) fail('timed out waiting');
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

SpawnSpec napSpec({ProcessOwner owner = const AppOwner()}) =>
    SpawnSpec(owner: owner, kind: ProcessKind.helper, exe: 'sleep', args: [nap]);

void main() {
  late Directory dir;
  final made = <ProcessSupervisor>[];

  setUpAll(() {
    // The launcher the supervisor finds in frontend/.tools (as in development).
    if (!File('.tools/everyai-exec').existsSync()) {
      final r = Process.runSync('tool/build_exec_helper.sh', const []);
      expect(r.exitCode, 0, reason: '${r.stderr}');
    }
  });

  ProcessSupervisor supervisor({SupervisorHooks hooks = const SupervisorHooks(timings: fast), String? ledgerDir}) {
    final s = ProcessSupervisor.create(hooks: hooks, ledgerDir: ledgerDir ?? '${dir.path}/l${made.length}');
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
    const id = ProcessIdentity(pid: 10, start: 's');
    final at = DateTime(2026);
    ChildState step(ChildState s, ChildChange e) => switch (nextChildState(s, e)) {
      ChildMoves(:final next) => next,
      ChildStays() => s,
      ChildRefused() => throw StateError('refused'),
    };
    bool refused(ChildState s, ChildChange e) => nextChildState(s, e) is ChildRefused;

    test('the edges of the diagram', () {
      var s = step(const ChildStarting(), ChildSpawned(10, at));
      expect(s, ChildLaunched(10, at));
      expect(
        step(s, const ChildUnverifiable('no table')),
        ChildUnverified(10, at, 'no table'),
        reason: 'its start time could not be read',
      );
      expect(step(ChildUnverified(10, at, 'x'), ChildLanded(id, at)), ChildRunning(id, at));
      expect(
        step(ChildUnverified(10, at, 'x'), ChildTermSent(at)),
        ChildTerming(const ProcessIdentity(pid: 10, start: unknownStart), at),
      );
      expect(step(s, ChildExitSeen(ExitCode(0), at)), ChildExited(ExitCode(0), at));
      s = step(s, ChildLanded(id, at));
      expect(s, ChildRunning(id, at));
      s = step(s, ChildTermSent(at));
      expect(s, isA<ChildTerming>());
      expect(step(s, ChildTermSent(at)), s, reason: 'a second TERM joins');
      s = step(s, ChildKillSent(at));
      expect(s, isA<ChildKilling>());
      s = step(s, ChildExitSeen(ExitCode(-9), at));
      expect(s, ChildExited(ExitCode(-9), at));
      expect(step(s, ChildExitSeen(SeenGone(), at)), s, reason: 'the exit future after a scan saw it gone');
      expect(step(s, const ChildSurvivors([id], 'left')), isA<ChildNotClosed>(), reason: 'its group left processes');
      final nc = step(ChildKilling(id, at), const ChildSurvivors([id], 'x'));
      expect(nc, const ChildNotClosed([id], 'x'));
      expect(step(nc, ChildTermSent(at)), ChildTerming(id, at), reason: 'a retry');
      expect(step(nc, ChildExitSeen(SeenGone(), at)), ChildExited(SeenGone(), at));
      expect(step(const ChildStarting(), const ChildFailedToStart('no')), const ChildStartFailed('no'));
      expect(step(ChildRunning(id, at), ChildKillSent(at)), ChildKilling(id, at));
    });

    test('refused edges: recorded, and the state stays', () {
      expect(refused(const ChildStarting(), ChildTermSent(at)), isTrue, reason: 'a stop waits for the start');
      expect(refused(const ChildStarting(), ChildLanded(id, at)), isTrue);
      expect(refused(ChildRunning(id, at), ChildLanded(id, at)), isTrue);
      expect(refused(ChildRunning(id, at), const ChildSurvivors([id], 'x')), isTrue);
      expect(refused(ChildRunning(id, at), ChildSpawned(1, at)), isTrue);
      expect(refused(ChildExited(SeenGone(), at), ChildLanded(id, at)), isTrue);
      for (final e in [ChildLanded(id, at), ChildTermSent(at), ChildExitSeen(SeenGone(), at)]) {
        expect(refused(const ChildStartFailed('x'), e), isTrue);
      }
      assertOnRefusedChildTransition = false;
      refusedChildTransitions.clear();
      final s = applyChildEvent(ChildExited(SeenGone(), at), ChildLanded(id, at), label: 't');
      expect(s, ChildExited(SeenGone(), at));
      expect(refusedChildTransitions.single.label, 't');
      assertOnRefusedChildTransition = true;
    });
  });

  group('starting', () {
    test('a child leads a session of its own from the start, has no terminal, and carries its tags', () async {
      final s = supervisor();
      final p = await s.spawn(napSpec(owner: const SessionOwner('s1')));
      expect(p.pid, isNotNull, reason: 'known as soon as spawn returns');
      final id = await p.landed;
      expect(pgidOf(p.pid!), p.pid, reason: 'its own group');
      expect(pgidOf(p.pid!), isNot(pgidOf(pid)));
      expect(id.pid, p.pid);
      expect(id.leadsGroup, isTrue);
      expect(id.start, startOf(id.pid));

      final r = await s.runBounded(
        '/bin/sh',
        [
          '-c',
          'echo "\$EVERYAI_APP|\$EVERYAI_OWNER|\$EVERYAI_SESSION|\$$childEnvVar"; '
              r'ps -o pid=,pgid=,sess=,tty= -p $$',
          marker,
        ],
        owner: const SessionOwner('s1'),
        timeout: const Duration(seconds: 10),
      );
      final lines = const LineSplitter().convert((r as Finished).stdout);
      expect(lines.first, startsWith('${s.appTag}|session:s1|s1|'));
      expect(s.tagsFor(const SessionOwner('s1')), {
        appEnvVar: s.appTag,
        ownerEnvVar: 'session:s1',
        sessionTagEnvVar: 's1',
      });
      final [shPid, shPgid, _, tty] = lines[1].trim().split(RegExp(r'\s+'));
      expect(shPgid, shPid, reason: 'a one-shot leads its own group too');
      expect(tty, anyOf('??', '?'), reason: 'no controlling terminal');

      expect(await p.stop(), isA<Ended>());
      expect(p.state, isA<ChildExited>());
      expect(running(id.pid), isFalse);
    });

    test('a child reading /dev/tty gets an error at once instead of hanging', () async {
      final r = await supervisor().runBounded('/bin/sh', [
        '-c',
        'cat /dev/tty',
        marker,
      ], timeout: const Duration(seconds: 5));
      expect(r, isA<Finished>());
      expect((r as Finished).code, isNot(0));
    });

    test(
      'the program is looked up on PATH, never through a shell (exported functions and builtins mean nothing)',
      () async {
        final s = supervisor();
        final a = await s.runBounded(
          'sleep',
          const ['0'],
          env: const {'BASH_FUNC_sleep%%': '() { echo hijacked; }'},
          timeout: const Duration(seconds: 5),
        );
        expect((a as Finished).code, 0);
        expect(a.stdout, isEmpty);
        final b = await s.runBounded('echo', const ['-n', 'x'], timeout: const Duration(seconds: 5));
        expect((b as Finished).stdout, 'x', reason: '/bin/echo, not a builtin');
      },
    );

    test('missing or not executable: a start failure, like Process.start', () async {
      final s = supervisor();
      final plain = File('${dir.path}/not-exec')..writeAsStringSync('#!/bin/sh\necho hi\n');
      await expectLater(
        s.spawn(SpawnSpec(owner: const AppOwner(), kind: ProcessKind.helper, exe: plain.path)),
        throwsA(isA<ProcessException>().having((e) => e.errorCode, 'errorCode', 13)),
      );
      await expectLater(
        s.spawn(const SpawnSpec(owner: AppOwner(), kind: ProcessKind.helper, exe: 'no-such-program-at-all')),
        throwsA(isA<ProcessException>().having((e) => e.errorCode, 'errorCode', 2)),
      );
      expect(await s.runBounded(plain.path, const [], timeout: const Duration(seconds: 5)), isA<StartFailed>());
      expect(s.children, isEmpty);
    });

    for (final via in [LaunchVia.helper, if (Platform.isMacOS) LaunchVia.perl]) {
      test('${via.name}: the pid is the program, and a signal reads as a negative code', () async {
        final s = supervisor(
          hooks: SupervisorHooks(timings: fast, launch: via),
        );
        final p = await s.spawn(napSpec());
        await p.landed;
        expect(pgidOf(p.pid!), p.pid);
        expect(_ps(['-o', 'command=', '-p', '${p.pid}']), '/bin/sleep $nap', reason: 'nothing in between');
        expect(p.signal(ProcessSignal.sigterm), isTrue);
        expect(await p.exitCode, -15);
      });
    }

    test('without a launcher the child shares the app\'s group, explicitly, and is ended by its tree', () async {
      final signals = <int>[];
      final s = supervisor(
        hooks: SupervisorHooks(
          timings: fast,
          launch: LaunchVia.shared,
          signal: (p, sig) {
            signals.add(p);
            return Process.killPid(p, sig);
          },
        ),
      );
      final p = await s.spawn(sh('sleep $nap & wait'));
      final id = await p.landed;
      expect(id.group, SharedGroup(pgidOf(pid)));
      expect(await p.stop(), isA<Ended>());
      expect(signals.where((x) => x < 0), isEmpty, reason: 'never the app\'s group');
    });
  });

  group('stopping', () {
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

    test('a polite stop goes first; a child that takes it gets no signal', () async {
      final signals = <int>[];
      final s = supervisor(
        hooks: SupervisorHooks(
          timings: fast,
          signal: (p, sig) {
            signals.add(p);
            return Process.killPid(p, sig);
          },
        ),
      );
      final p = await s.spawn(
        SpawnSpec(
          owner: const AppOwner(),
          kind: ProcessKind.mcp,
          exe: '/bin/sh',
          args: ['-c', 'read x; exit 0', marker],
          politeStop: PoliteStop((c) => (c as SupervisedProcess).stdin.close()),
        ),
      );
      await p.landed;
      expect(await p.stop(), isA<Ended>());
      expect(await p.exitCode, 0);
      expect(signals, isEmpty);
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
      final p = await s.spawn(napSpec());
      final id = await p.landed;
      final a = p.stop(), b = s.stop(p);
      expect(identical(a, b), isTrue);
      await a;
      expect(terms.where((t) => t == id.pid), hasLength(1));
      expect(terms.where((t) => t == -id.pid), hasLength(1));
    });

    test('a stop of a child still starting ends it once it is started', () async {
      final s = supervisor();
      final spawned = s.spawn(napSpec());
      expect(s.children.single.state, const ChildStarting());
      final stopped = s.children.single.stop();
      final p = await spawned;
      expect(await stopped, isA<Ended>());
      expect(p.state, isA<ChildExited>());
      expect(running(p.pid!), isFalse);
    });

    test('stopOwner ends an orphan that left the group, found by its owner tag', () async {
      // The orphan must show its environment: Linux shows every process's, macOS hides Apple binaries' (so the
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
      final out = await s.stopOwner(owner);
      expect(out, isA<Ended>());
      expect((out as Ended).pids, contains(orphan));
      expect(running(orphan), isFalse);
    });

    test('an escapee that left with its own session and a hidden environment is ended or reported, never "Ended" '
        'without it', () async {
      final s = supervisor();
      final p = await s.spawn(
        sh(
          '/usr/bin/perl -MPOSIX -e \'fork and exit; POSIX::setsid(); exec "sleep", "$nap"\'; '
          'exec sleep 30.${pid}1',
        ),
      );
      await p.landed;
      await eventually(() => orphanNaps().isNotEmpty);
      final escapee = orphanNaps().single;
      final out = await p.stop();
      switch (out) {
        case Ended(:final pids):
          expect(pids, contains(escapee));
          expect(running(escapee), isFalse);
        case Unaccounted(:final candidates):
          expect(candidates, contains(escapee));
          if (Platform.isLinux) fail('Linux reads every environment: the tag should have found it');
        default:
          fail('unexpected $out');
      }
      Process.killPid(escapee, ProcessSignal.sigkill);
    });

    test('a failed scan is never "nothing left": ScanFailed, NotClosed, and re-checked until it is gone', () async {
      var failing = false;
      final real = ProcessSupervisor.create();
      final s = supervisor(
        hooks: SupervisorHooks(
          timings: const StopTimings(termGrace: Duration(milliseconds: 100), killWait: Duration(milliseconds: 100)),
          scan: ({required env}) async => failing ? const ScanFailed('injected') : real.scan(env: env),
          signal: (_, _) => true, // signals "sent" but nothing happens
        ),
      );
      final p = await s.spawn(napSpec());
      final id = await p.landed;
      failing = true;
      final out = await p.stop();
      expect(out, isA<ScanFailed>());
      expect(p.state, isA<ChildNotClosed>());
      expect(s.children, contains(p));
      expect(running(id.pid), isTrue);
      Process.killPid(id.pid, ProcessSignal.sigkill);
      expect(await p.exitCode, -9);
      expect(p.state, isA<ChildExited>(), reason: 'its own exit future');
    });

    test('an adopted child not closed for want of a scan is re-checked once scans work again', () async {
      var failing = false;
      final real = ProcessSupervisor.create();
      final s = supervisor(
        hooks: SupervisorHooks(
          timings: const StopTimings(termGrace: Duration(milliseconds: 100), killWait: Duration(milliseconds: 100)),
          scan: ({required env}) async => failing ? const ScanFailed('injected') : real.scan(env: env),
          signal: (_, _) => true,
        ),
      );
      final raw = await Process.start('sleep', [nap]);
      final c = s.adopt(raw.pid, const SpawnSpec(owner: AppOwner(), kind: ProcessKind.pty, exe: 'sleep'));
      await c.landed;
      failing = true;
      expect(await c.stop(), isA<ScanFailed>());
      expect(c.state, isA<ChildNotClosed>());
      raw.kill(ProcessSignal.sigkill);
      await raw.exitCode;
      failing = false;
      await c.ended.timeout(const Duration(seconds: 5));
      expect(c.state, isA<ChildExited>());
    });

    test('an unkillable child is NotClosed, stays listed, and is seen gone once it is', () async {
      final s = supervisor(
        hooks: const SupervisorHooks(
          timings: StopTimings(termGrace: Duration(milliseconds: 100), killWait: Duration(milliseconds: 200)),
          signal: _ignore,
        ),
      );
      final p = await s.spawn(napSpec());
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
      final f = r as Finished;
      expect((f.code, f.stdout, f.stderr, f.leftRunning), (3, 'got hi\n', 'err\n', null));
      expect(f.stdoutBytes, utf8.encode('got hi\n'));
    });

    test('a timeout kills the command and its child, verified', () async {
      final r = await supervisor().runBounded('/bin/sh', [
        '-c',
        'sleep $nap & sleep $nap',
        marker,
      ], timeout: const Duration(milliseconds: 400));
      final kill = (r as TimedOut).kill;
      expect(kill, isA<Ended>());
      expect((kill as Ended).pids.length, greaterThanOrEqualTo(3));
      expect(leftovers(), isEmpty);
    });

    test('a program that exited while something it started holds its pipes: Finished, with that stopped', () async {
      final sw = Stopwatch()..start();
      final r = await supervisor().runBounded('/bin/sh', [
        '-c',
        'sleep $nap & echo started; exit 0',
        marker,
      ], timeout: const Duration(seconds: 20));
      final f = r as Finished;
      expect((f.code, f.stdout), (0, 'started\n'));
      expect(f.leftRunning, isA<Ended>());
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)), reason: 'not the timeout');
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

    test('50 MB of output with a cap: the cap is kept, the rest dropped, memory stays put', () async {
      final before = ProcessInfo.currentRss;
      final r = await supervisor().runBounded(
        '/bin/sh',
        ['-c', 'head -c 52428800 /dev/zero', marker],
        maxOutputBytes: 1 << 20,
        timeout: const Duration(seconds: 30),
      );
      final f = r as Finished;
      expect(f.code, 0);
      expect(f.stdoutBytes.length, 1 << 20);
      expect(f.truncated, isTrue);
      expect(ProcessInfo.currentRss - before, lessThan(100 << 20));
    });

    test('a cancel stops it', () async {
      final cancel = Completer<void>();
      final r = supervisor().runBounded('sleep', [nap], timeout: const Duration(seconds: 30), cancel: cancel.future);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      cancel.complete();
      final res = await r;
      expect((res as Cancelled).kill, isA<Ended>());
    });
  });

  group('the supervisor', () {
    test('quitting: spawns and adoptions are refused, and a quit can\'t race a new ledger', () async {
      final s = supervisor();
      await s.spawn(napSpec());
      final quit = s.stopAll();
      await expectLater(s.spawn(napSpec()), throwsA(isA<SupervisorClosed>()));
      expect(() => s.adopt(1, napSpec()), throwsA(isA<SupervisorClosed>()));
      expect((await quit).clean, isTrue);
      await expectLater(s.spawn(napSpec()), throwsA(isA<SupervisorClosed>()));
      expect(identical(s.stopAll(), s.stopAll()), isFalse); // both the same finished report
      expect(await s.stopAll(), same(await quit));
      final files = Directory(await s.ledgerDirectory).listSync().map((e) => e.uri.pathSegments.last).toList();
      expect(files, ['quit.json'], reason: 'the clean ledger and list are gone, and nothing was made again');
    });

    test('children and counts are observable', () async {
      final s = supervisor();
      final seen = <int>[];
      s.childrenListenable.addListener(() => seen.add(s.childrenListenable.value.length));
      final p = await s.spawn(napSpec(owner: const SessionOwner('x')));
      expect(s.liveCount(const SessionOwner('x')), 1);
      await p.stop();
      expect(s.liveCount(const SessionOwner('x')), 0);
      expect(seen.last, 0);
      expect(seen, contains(1));
    });

    test('the ledger is this run\'s own (pid and start time) and records launch, run, states and exit', () async {
      final s = supervisor();
      final p = await s.spawn(napSpec());
      await p.landed;
      final ledgerDir = await s.ledgerDirectory;
      final ledger = File('$ledgerDir/ledger-$pid-${startOf(pid)}.jsonl');
      await p.stop();
      await eventually(() => ledger.existsSync() && ledger.readAsStringSync().contains('"t":"exit"'));
      final lines = ledger.readAsLinesSync().map(LedgerLine.decode).toList();
      expect(lines.first, isA<LedgerApp>());
      expect(lines.whereType<LedgerSpawn>().single.label, 'sleep');
      expect(lines.whereType<LedgerLaunch>().single.pid, p.pid);
      expect(lines.whereType<LedgerRun>().single.identity.pid, p.pid);
      expect(lines.whereType<LedgerState>().map((l) => l.state), contains('terming'));
      expect(lines.whereType<LedgerExit>(), hasLength(1));
      expect(LedgerFold.of(ledger.readAsLinesSync()).live, isEmpty);
      expect((await s.stopAll()).clean, isTrue);
      expect(File('$ledgerDir/quit.json').existsSync(), isTrue);
      expect(ledger.existsSync(), isFalse);
    });

    test('a ledger left by a dead run with this pid is never appended to or taken back', () async {
      final helper = supervisor();
      final live = await helper.spawn(napSpec());
      final liveId = await live.landed;
      final d = '${dir.path}/stale';
      Directory(d).createSync();
      final stale = File('$d/ledger-$pid-Mon_Jan_1_00:00:00_2001.jsonl')
        ..writeAsStringSync(
          [
            LedgerApp(pid: pid, start: 'Mon_Jan_1_00:00:00_2001'),
            const LedgerSpawn(id: 1, exe: 'sleep', owner: 'app', kind: 'helper', label: 'old'),
            LedgerRun(id: 1, identity: liveId),
          ].map((l) => l.encode()).join(),
        );
      final legacy = File('$d/ledger-$pid.jsonl')..writeAsStringSync(stale.readAsStringSync());
      final before = stale.readAsStringSync();
      final s = supervisor(ledgerDir: d);
      final mine = await s.spawn(napSpec());
      await mine.landed;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(s.children.map((c) => c.pid), [mine.pid]);
      expect(stale.readAsStringSync(), before);
      expect(legacy.readAsStringSync(), before);
    });

    test('this run reopened (a hot restart) takes back what its ledger still runs', () async {
      final d = '${dir.path}/same';
      final first = supervisor(ledgerDir: d);
      final p = await first.spawn(napSpec());
      await p.landed;
      await eventually(() => File('$d/ledger-$pid-${startOf(pid)}.jsonl').existsSync());
      await Future<void>.delayed(const Duration(milliseconds: 100)); // the run line written
      final again = supervisor(ledgerDir: d);
      await again.ledgerDirectory;
      expect(again.children.map((c) => c.pid), [p.pid]);
      expect(await again.children.single.stop(), isA<Ended>());
      await p.ended;
    });

    test('the sweep ends what a dead run listed, only where pid and start time (or launch time) match', () async {
      final helper = supervisor();
      final ours = await helper.spawn(napSpec());
      final reused = await helper.spawn(napSpec());
      final launchedAt = DateTime.now();
      final early = await helper.spawn(napSpec());
      final a = await ours.landed, b = await reused.landed;
      await early.landed;
      final gone = await Process.start('true', const []);
      await gone.exitCode;
      final s = supervisor();
      final ledgerDir = await s.ledgerDirectory;
      final dead = File('$ledgerDir/ledger-${gone.pid}-Thu_Jan_1_00:00:00_1970.jsonl')
        ..writeAsStringSync(
          [
            LedgerApp(pid: gone.pid, start: 'Thu_Jan_1_00:00:00_1970'),
            const LedgerSpawn(id: 1, exe: 'sleep', owner: 'app', kind: 'helper', label: 'ours'),
            LedgerRun(id: 1, identity: a),
            const LedgerSpawn(id: 2, exe: 'sleep', owner: 'app', kind: 'helper', label: 'reused'),
            LedgerRun(
              id: 2,
              identity: ProcessIdentity(pid: b.pid, start: 'Mon_Jan_1_00:00:00_2001'),
            ),
            const LedgerSpawn(id: 3, exe: 'sleep', owner: 'app', kind: 'helper', label: 'early'),
            LedgerLaunch(id: 3, pid: early.pid!, at: launchedAt),
          ].map((l) => l.encode()).join(),
        );
      final report = await s.sweepPreviousRuns();
      expect(report.failure, isNull);
      expect(report.ended.map((e) => e.pid), unorderedEquals([a.pid, early.pid]));
      expect(report.leftAlone.map((e) => e.pid), [b.pid]);
      expect(report.survived, isEmpty);
      expect(s.lastSweep.value, same(report));
      expect(dead.existsSync(), isFalse);
      expect(running(a.pid), isFalse);
      expect(running(early.pid!), isFalse);
      expect(running(b.pid), isTrue, reason: 'another start time: not ours');
    });

    test('a supervisor that sweeps at start does so once, on its first use, and keeps the report', () async {
      final s = ProcessSupervisor.create(
        hooks: const SupervisorHooks(timings: fast),
        ledgerDir: '${dir.path}/app',
        sweepAtStart: true,
      );
      made.add(s);
      expect(s.lastSweep.value, isNull);
      final raw = await Process.start('sleep', [nap]);
      final c = s.adopt(raw.pid, napSpec(), exitCode: raw.exitCode);
      await c.landed;
      await eventually(() => s.lastSweep.value != null);
      expect(s.lastSweep.value!.failure, isNull);
      expect(await s.sweepPreviousRuns(), same(s.lastSweep.value));
      expect(await c.stop(), isA<Ended>());
    });

    test(
      'the watchdog ends a listed group, an adopted child\'s whole tree, and nothing with another start time',
      () async {
        final s = supervisor();
        final group = await s.spawn(sh('sleep $nap & wait'));
        final stranger = await s.spawn(napSpec());
        final g = await group.landed, st = await stranger.landed;
        await eventually(() => _ps(['-A', '-o', 'pgid=']).split('\n').where((l) => l.trim() == '${g.pid}').length == 2);
        // An adopted-like child in this process's group, with a child of its own the list doesn't name.
        final shared = await Process.start('/bin/sh', ['-c', 'sleep $nap & wait', marker]);
        await eventually(() => _ps(['-A', '-o', 'ppid=']).split('\n').any((l) => l.trim() == '${shared.pid}'));
        final sharedId = ProcessIdentity(pid: shared.pid, start: startOf(shared.pid), group: SharedGroup(pgidOf(pid)));
        // A stand-in app that dies in a second (not the test runner).
        final app = await Process.start('sleep', ['1']);
        final appStart = startOf(app.pid);
        final list = File('${dir.path}/watch.list')
          ..writeAsStringSync(
            watchList([
              (id: g, at: null),
              (id: sharedId, at: null),
              (id: ProcessIdentity(pid: st.pid, start: 'Mon_Jan_1_00:00:00_2001'), at: null),
            ]),
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
          '${dir.path}/wd.pid',
        ]);
        expect(run.exitCode, 0, reason: '${run.stderr}');
        await group.ended.timeout(const Duration(seconds: 5));
        expect(_ps(['-A', '-o', 'pgid=']).split('\n').where((l) => l.trim() == '${g.pid}'), isEmpty);
        expect(await shared.exitCode.timeout(const Duration(seconds: 5)), isNot(0));
        expect(running(st.pid), isTrue);
        expect(list.existsSync(), isFalse);
        expect(File('${dir.path}/wd.pid').existsSync(), isFalse);
      },
    );

    test('the watchdog matches a process listed before its start time was read by when it started', () async {
      final raw = await Process.start('sleep', [nap]);
      final app = await Process.start('sleep', ['0.5']);
      final list = File('${dir.path}/watch.list')
        ..writeAsStringSync(watchList([(id: ProcessIdentity(pid: raw.pid, start: unknownStart), at: DateTime.now())]));
      final run = await Process.run('/bin/sh', [
        '-c',
        watchdogScript,
        'everyai-watchdog',
        '${app.pid}',
        startOf(app.pid),
        list.path,
        'nobody:none',
        '0.1',
        '0.2',
        '',
      ]);
      expect(run.exitCode, 0, reason: '${run.stderr}');
      expect(await raw.exitCode.timeout(const Duration(seconds: 5)), isNot(0));
    });

    test('spawn overhead against plain Process.start (50 × /usr/bin/true)', () async {
      final s = supervisor();
      Future<Duration> time(Future<int> Function() run) async {
        final sw = Stopwatch()..start();
        for (var i = 0; i < 50; i++) {
          await run();
        }
        return sw.elapsed;
      }

      await Process.start('/usr/bin/true', const []).then((p) => p.exitCode); // warm up
      final plain = await time(() => Process.start('/usr/bin/true', const []).then((p) => p.exitCode));
      final supervised = await time(
        () => s
            .spawn(const SpawnSpec(owner: AppOwner(), kind: ProcessKind.oneShot, exe: '/usr/bin/true'))
            .then((p) => p.exitCode),
      );
      final extra = (supervised - plain).inMicroseconds / 50 / 1000;
      // ignore: avoid_print
      print(
        'spawn: plain ${(plain.inMicroseconds / 50 / 1000).toStringAsFixed(2)} ms, supervised '
        '${(supervised.inMicroseconds / 50 / 1000).toStringAsFixed(2)} ms, extra ${extra.toStringAsFixed(2)} ms each',
      );
      expect(extra, lessThan(10));
    });
  });
}

bool _ignore(int pid, ProcessSignal signal) => true;
