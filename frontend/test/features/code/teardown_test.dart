// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:io';

import 'package:every_ai/app/app_quit.dart';
import 'package:every_ai/core/process/supervisor.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("Stop ends a session's shells (and what they started) but keeps its lead CLI", () async {
    final sup = ProcessSupervisor.instance;
    const tag = 'teardown-test';
    final shell = await sup.spawn(
      SpawnSpec(
        owner: const SessionOwner(tag),
        kind: ProcessKind.shell,
        exe: '/bin/sh',
        args: ['-c', 'sleep 60 & sleep 60'],
      ),
    );
    final cli = await sup.spawn(
      SpawnSpec(owner: const SessionOwner(tag), kind: ProcessKind.leadCli, exe: '/bin/sleep', args: ['60']),
    );
    await shell.landed;
    await cli.landed;
    final outcome = await stopSessionChildren(tag);
    expect(outcome, isA<Ended>());
    expect(shell.state.live, isFalse);
    expect(cli.state.live, isTrue);
    expect(await cli.stop(), isA<Ended>());
  });

  test('a delete moves only along its table', () {
    expect(teardownEdge(null, const TeardownRequested()), isTrue);
    expect(teardownEdge(const TeardownRequested(), const TeardownStoppingRun()), isTrue);
    expect(teardownEdge(const TeardownStoppingRun(), const TeardownStoppingProcesses()), isTrue);
    expect(teardownEdge(const TeardownStoppingProcesses(), const TeardownReleasing()), isTrue);
    expect(teardownEdge(const TeardownReleasing(), const TeardownNotClosed([1], 'x')), isTrue);
    expect(teardownEdge(const TeardownNotClosed([1], 'x'), const TeardownRequested()), isTrue);
    // Never forgotten before its processes were stopped.
    expect(teardownEdge(const TeardownRequested(), const TeardownGone()), isFalse);
    expect(teardownEdge(const TeardownStoppingRun(), const TeardownGone()), isFalse);
    expect(ProcessesNotClosed.of(const Survived([7, 8], 'still there')).message, contains('Not closed: 2 processes'));
  });

  test('quit runs its steps in order, each bounded, then ends what is left', () async {
    final dir = await Directory.systemTemp.createTemp('quit-test');
    addTearDown(() => dir.delete(recursive: true));
    final sup = ProcessSupervisor.create(ledgerDir: dir.path);
    final left = await sup.spawn(
      const SpawnSpec(owner: AppOwner(), kind: ProcessKind.helper, exe: '/bin/sleep', args: ['60']),
    );
    await left.landed;
    final order = <String>[];
    final report = await runQuit(sup, [
      (
        name: 'one',
        within: const Duration(seconds: 1),
        run: () async {
          order.add('one');
          return const Ended([]);
        },
      ),
      (
        name: 'slow',
        within: const Duration(milliseconds: 50),
        run: () {
          order.add('slow');
          return Completer<KillOutcome>().future;
        },
      ),
      (name: 'throws', within: const Duration(seconds: 1), run: () async => throw StateError('boom')),
      (
        name: 'last',
        within: const Duration(seconds: 1),
        run: () async {
          order.add('last');
          return const Ended([]);
        },
      ),
    ]);
    expect(order, ['one', 'slow', 'last']);
    expect([for (final s in report.steps) s.$1], ['one', 'slow', 'throws', 'last']);
    expect(report.steps[1].$2, isA<ScanFailed>());
    expect(report.steps[2].$2, isA<ScanFailed>());
    expect(report.clean, isFalse);
    expect(left.state.live, isFalse);
    expect(File('${dir.path}/quit.json').existsSync(), isTrue);
  });
}
