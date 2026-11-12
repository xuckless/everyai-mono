import 'dart:async';

import 'package:every_ai/features/code/drivers/detection/desktop_apps.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/features/code/drivers/driver.dart';
import 'package:every_ai/features/code/drivers/driver_policy.dart';
import 'package:every_ai/features/code/drivers/driver_process.dart';
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Fake implements HarnessDriver {
  _Fake(this.id, this.status);
  final String id;
  final Future<DriverStatus> Function() status;
  var detects = 0;

  @override
  DriverInfo get info => DriverInfo(id: id, label: id);
  @override
  Set<DriverCap> get caps => const {};
  @override
  Future<DriverStatus> detect() {
    detects++;
    return status();
  }

  @override
  Future<List<DriverModel>> models() async => const [];
  @override
  Future<HarnessSession> start(SessionSpec spec) => throw UnimplementedError();
  @override
  Future<HarnessSession> attach(String conversationId) => throw UnimplementedError();
  @override
  Future<Map<String, ExecutionStatus>> statuses(List<String> conversationIds) async => const {};
}

ProviderContainer _container(
  Map<String, HarnessDriver> drivers, {
  Preferences? prefs,
  DriverStatuses Function()? notifier,
}) {
  final c = ProviderContainer(
    overrides: [
      driverRegistryProvider.overrideWithValue(DriverRegistry(drivers)),
      preferencesProvider.overrideWithValue(prefs ?? Preferences.inMemory()),
      driverStatusesProvider.overrideWith(notifier ?? () => DriverStatuses(scanApps: _noApps, loadShell: _noShell)),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

/// The login shell is never read in these tests.
Future<void> _noShell() async {}

void main() {
  group('the scan', () {
    test('installed, missing, a throw and no answer each become a status', () async {
      final never = Completer<DriverStatus>();
      final c = _container({
        'a': _Fake('a', () async => const DriverStatus(installed: true, path: '/bin/a', version: '1.2')),
        'b': _Fake('b', () async => const DriverStatus()),
        'c': _Fake('c', () async => throw StateError('broken')),
        'd': _Fake('d', () => never.future),
      }, notifier: () => DriverStatuses(scanApps: _noApps, loadShell: _noShell, timeout: Duration.zero));
      final s = await c.read(driverStatusesProvider.future);
      expect((s['a']!.installed, s['a']!.version), (true, '1.2'));
      expect(s['b']!.installed, isFalse);
      expect((s['c']!.installed, s['c']!.problem), (false, "Couldn't check: Bad state: broken"));
      // Nothing known and no answer: not offered on a guess.
      expect((s['d']!.installed, s['d']!.problem), (false, noAnswerProblem));
    });

    test('checks at most four drivers at once', () async {
      final gates = [for (var i = 0; i < 6; i++) Completer<DriverStatus>()];
      var running = 0;
      var most = 0;
      final drivers = {
        for (var i = 0; i < 6; i++)
          'd$i': _Fake('d$i', () async {
            running++;
            most = running > most ? running : most;
            try {
              return await gates[i].future;
            } finally {
              running--;
            }
          }),
      };
      final c = _container(drivers);
      final done = c.read(driverStatusesProvider.future);
      await pumpEventQueue();
      expect(drivers.values.where((d) => d.detects > 0).length, 4);
      for (final g in gates) {
        g.complete(const DriverStatus(installed: true));
        await pumpEventQueue();
      }
      expect((await done).length, 6);
      expect(most, 4);
    });

    test('two refreshes at once share one check', () async {
      final gate = Completer<DriverStatus>();
      final a = _Fake('a', () => gate.future);
      final c = _container({'a': a});
      final first = c.read(driverStatusesProvider.future);
      final n = c.read(driverStatusesProvider.notifier);
      final r1 = n.refresh();
      final r2 = n.refresh();
      gate.complete(const DriverStatus(installed: true));
      await Future.wait([first, r1, r2]);
      expect(a.detects, 1);
    });
  });

  group('one driver again', () {});

  group('the kept check', () {});

  group('finding a CLI without a process', () {});

  group('the lead picker', () {
    const plain = DriverInfo(id: 'codex', label: 'Codex');

    test('offers EveryAI, the current pick and installed harnesses only', () {
      const everyai = DriverInfo(id: 'everyai', label: 'EveryAI');
      expect(offeredAsLead(everyai, null, current: 'everyai'), isTrue);
      expect(offeredAsLead(plain, null, current: 'everyai'), isFalse);
      expect(offeredAsLead(plain, const DriverStatus(), current: 'everyai'), isFalse);
      expect(offeredAsLead(plain, const DriverStatus(), current: 'codex'), isTrue);
      expect(offeredAsLead(plain, const DriverStatus(installed: true, signedIn: false), current: 'everyai'), isTrue);
    });
  });
}

Future<AppScan> _noApps() async => const AppScan();
