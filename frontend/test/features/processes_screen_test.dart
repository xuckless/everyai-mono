import 'dart:async';

import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/process/supervisor.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/session_notifications.dart';
import 'package:every_ai/features/processes/process_providers.dart';
import 'package:every_ai/features/processes/ui/processes_section.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

final class _Child extends Fake implements SupervisedChild {
  _Child(this.id, this.state);
  @override
  final int id;
  @override
  ChildState state;
  final String label = 'server';
  final _states = StreamController<ChildState>.broadcast();
  @override
  Stream<ChildState> get states => _states.stream;
  @override
  SpawnSpec get spec =>
      SpawnSpec(owner: const AppOwner(), kind: ProcessKind.localServer, exe: 'srv', label: label, port: 8080);
  @override
  int? get pid => 4000 + id;
  @override
  int? get port => 8080;
  @override
  String? get detail => null;
  void move(ChildState s) {
    state = s;
    _states.add(s);
  }
}

final class _Sup extends Fake implements ProcessSupervisor {
  _Sup(List<SupervisedChild> children) : list = ValueNotifier(children);
  final ValueNotifier<List<SupervisedChild>> list;
  ProcessScan nextScan = ScanFailed('not yet');
  KillOutcome stopOutcome = const Ended([]);
  final stopped = <int>[];
  @override
  List<SupervisedChild> get children => list.value;
  @override
  ValueListenable<List<SupervisedChild>> get childrenListenable => list;
  @override
  Future<ProcessScan> scan({bool env = false}) async => nextScan;
  @override
  Future<KillOutcome> stop(SupervisedChild child, {StopTimings? timings}) async {
    stopped.add(child.id);
    return stopOutcome;
  }

  @override
  final ValueListenable<SweepReport?> lastSweep = ValueNotifier(null);
  @override
  Future<String> get ledgerDirectory async => '';
}

final class _Notes implements SystemNotifier {
  final shown = <String>[];
  @override
  Future<void> show(String title, String body) async => shown.add('$title: $body');
}

final _id = ProcessIdentity(pid: 4001, start: 'Tue_Nov_11_10:00:00_2026');
Listed _table(List<ProcessIdentity> ids) => Listed(
  ProcessList([for (final i in ids) ScanRow(pid: i.pid, ppid: 1, pgid: i.pid, start: i.start, command: 'srv')]),
  at: DateTime(2026),
);

void main() {
  test('the join: running confirmed, running but missing, not closed, and a failed scan is never empty', () {
    final running = _Child(1, ChildRunning(_id, DateTime(2026)));
    final notClosed = _Child(2, ChildNotClosed([const ProcessIdentity(pid: 4002, start: 'x')], 'KILL ignored'));

    final listed = joinOwned([running, notClosed], _table([_id]));
    expect(listed, isA<OwnedListed>());
    expect(listed.rows.first.os, isA<OsConfirmed>());
    expect(ownedStateText(listed.rows.first), 'Running');
    expect(ownedStateText(listed.rows.last), 'Not closed: pids 4002');
    expect(listed.rows.last.loud, isTrue);

    final missing = joinOwned([running], _table(const []));
    expect(ownedStateText(missing.rows.single), 'Gone (unconfirmed)');

    final failed = joinOwned([running], const ScanFailed('ps: not found'));
    expect(failed, isA<OwnedScanFailed>());
    expect((failed as OwnedScanFailed).why, 'ps: not found');
    expect(failed.rows, hasLength(1));
  });

  test('notClosedProvider follows states and notifies once per child', () async {
    final child = _Child(1, ChildRunning(_id, DateTime(2026)));
    final notes = _Notes();
    final c = ProviderContainer(
      overrides: [
        processSupervisorProvider.overrideWithValue(_Sup([child])),
        systemNotifierProvider.overrideWithValue(notes),
      ],
    );
    addTearDown(c.dispose);
    c.listen(notClosedProvider, (_, _) {});
    expect(c.read(notClosedProvider), isEmpty);
    child.move(ChildNotClosed([_id], 'still there'));
    await Future<void>.delayed(Duration.zero);
    expect(c.read(notClosedProvider).single.id, 1);
    child.move(ChildNotClosed([_id], 'still there again'));
    await Future<void>.delayed(Duration.zero);
    expect(notes.shown, hasLength(1));
  });

  test('launch notice lines', () {
    expect(launchNoticeLines(const SweepReport(), const NoQuitRecord()), isEmpty);
    final lines = launchNoticeLines(
      const SweepReport(ended: [(pid: 1, label: 'a', why: ''), (pid: 2, label: 'b', why: '')]),
      parseQuitJson('{"at":"2026-11-11T00:00:00Z","ended":[],"survived":[{"label":"chrome","pids":[9],"reason":"x"}]}'),
    );
    expect(lines.map((l) => l.text), [
      'Cleaned up 2 processes left by the last run',
      "The last quit wasn't clean: chrome",
    ]);
    expect(lines.last.bad, isTrue);
  });

  testWidgets('the Settings section shows a Not closed row, and Stop reports the outcome', (tester) async {
    final notClosed = _Child(2, ChildNotClosed([const ProcessIdentity(pid: 4002, start: 'x')], 'KILL ignored'));
    final sup = _Sup([notClosed])
      ..nextScan = const ScanFailed('ps failed')
      ..stopOutcome = const Survived([4002], 'still running after SIGKILL');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          preferencesProvider.overrideWithValue(Preferences.inMemory()),
          processSupervisorProvider.overrideWithValue(sup),
        ],
        child: m.MaterialApp(
          home: EveryThemeScope(
            theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
            child: const m.Material(child: ProcessesSection()),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text("Couldn't read processes: ps failed"), findsOneWidget);
    expect(find.text('Not closed: pids 4002'), findsOneWidget);
    expect(find.text('Kill again'), findsOneWidget);
    expect(find.text('Stop all not closed'), findsOneWidget);

    await tester.tap(find.text('Kill again'));
    await tester.pump();
    await tester.pump();
    expect(sup.stopped, [2]);
    expect(find.textContaining('Not closed: pids 4002 (still running after SIGKILL)'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });
}
