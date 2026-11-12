// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';

import 'package:every_ai/core/process/budget.dart';
import 'package:every_ai/core/process/supervisor.dart';
import 'package:every_ai/features/code/harness/everyai/shell_io.dart';
import 'package:every_ai/features/code/shells/shell_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ScanRow row(int pid, int ppid, {String? tag}) => ScanRow(
    pid: pid,
    ppid: ppid,
    pgid: pid,
    start: 's$pid',
    command: 'x',
    env: tag == null ? const EnvRead({}) : EnvRead({sessionTagEnvVar: tag}),
  );

  test('counts a session\'s children, their trees and tagged processes', () {
    final table = ProcessList([row(10, 1), row(11, 10), row(12, 11), row(20, 1, tag: 's'), row(21, 20), row(30, 1)]);
    final counts = countSessionProcesses(table, ['s', 'other'], [(owner: const SessionOwner('s'), pid: 10)]);
    expect(counts, {'s': 5, 'other': 0});
    expect(judgeBudget(5, 4), isA<OverBudget>());
    expect(judgeBudget(4, 4), isA<WithinBudget>());
  });

  test('a breach stops the owner and tells the agent once', () async {
    // Fake pids: nothing is really signalled; a signal "ends" the process for the next scan.
    final alive = {5, 6, 7};
    final signalled = <int>{};
    final dir = await Directory.systemTemp.createTemp('budget');
    addTearDown(() => dir.delete(recursive: true));
    final sup = ProcessSupervisor.create(
      ledgerDir: dir.path,
      hooks: SupervisorHooks(
        scan: ({required env}) async => Listed(
          ProcessList([for (final p in alive) p == 5 ? row(5, 1, tag: 'run') : row(p, 5)]),
          at: DateTime.now(),
          withEnv: true,
        ),
        signal: (pid, _) {
          signalled.add(pid.abs());
          alive.remove(pid.abs());
          return true;
        },
      ),
    );
    final breaches = <String>[];
    final watch = ProcessBudgetWatch(
      supervisor: sup,
      running: () => {'run'},
      limit: () => 2,
      onBreach: (id, over, _) => breaches.add('$id ${over.count}/${over.limit}'),
    );
    await watch.check();
    expect(breaches, ['run 3/2']);
    expect(signalled, containsAll({5, 6, 7}));
    expect(ProcessBudgetWatch.takeNote('run'), contains('more than 2 processes'));
    expect(ProcessBudgetWatch.takeNote('run'), isNull);
  }, skip: Platform.isWindows);

  test('the 17th live background shell is refused with how to free one', () async {
    final dir = await Directory.systemTemp.createTemp('bgcap');
    addTearDown(() => dir.delete(recursive: true));
    final shell = SessionShell(
      root: dir.path,
      sessionTag: 'bgcap',
      scratchDir: '${dir.path}/.sh',
      registry: ShellRegistry.forTest(),
    );
    final started = [for (var i = 0; i < maxBackgroundShells; i++) await shell.start('sleep 30')];
    addTearDown(() async {
      for (final b in started) {
        await b.kill();
      }
    });
    await expectLater(
      shell.start('sleep 30'),
      throwsA(isA<TooManyBackgroundShells>().having((e) => e.message, 'message', contains('kill_shell'))),
    );
  }, skip: Platform.isWindows);
}
