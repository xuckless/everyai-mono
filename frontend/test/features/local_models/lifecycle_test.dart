import 'package:every_ai/core/local_backend/local_backend.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/process/process_model.dart' show Ended, KillOutcome, ScanFailed, Survived;
import 'package:every_ai/features/local_models/data/local_system.dart';
import 'package:every_ai/features/local_models/data/local_http.dart';
import 'package:every_ai/features/code/gateway_key.dart';

import 'dart:async';

import 'package:every_ai/features/local_models/local_model_bridge.dart' show localDetectionProvider, localShutdown;
import 'package:every_ai/features/local_models/local_models_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

final class _Store implements SecretStore {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

final _info = LocalBackendInfo(baseUrl: Uri.parse('http://127.0.0.1:1/'), token: 't');

void main() {
  group('server phases', () {
    const stopped = ServerStopped();
    const starting = ServerStarting();
    const ours = ServerRunning(ServerOwner.everyai);
    ServerRunning(ServerOwner.outside);

    test('start, run, stop', () {
      expect(nextPhase(stopped, const StartAsked()), starting);
      expect(nextPhase(starting, const Started(ServerOwner.everyai)), ours);
      expect(nextPhase(ours, const StopAsked()), const ServerStopping(ServerOwner.everyai));
      expect(nextPhase(const ServerStopping(ServerOwner.everyai), const StopDone()), stopped);
    });

    test('a refused move is recorded (and asserts in debug)', () {
      assertOnRefusedServerTransition = false;
      addTearDown(() => assertOnRefusedServerTransition = true);
      refusedServerTransitions.clear();
      expect(applyServerEvent('x', stopped, const StopDone()), isNull);
      expect(refusedServerTransitions.single.server, 'x');
    });
  });

  group('bundled server phases', () {
    test('closed is final: nothing starts after quit', () {
      for (final p in [
        const BackendIdle(),
        const BackendStarting(),
        BackendRunning(_info),
        const BackendCrashed('x'),
        const BackendStopping(),
      ]) {
        expect(nextBackendPhase(p, const BackendCloseAsked()), isA<BackendClosed>());
      }
      expect(nextBackendPhase(const BackendClosed(), const BackendStartAsked()), isNull);
      expect(nextBackendPhase(const BackendClosed(), BackendReady(_info)), isNull);
    });
  });

  group('lifecycles', () {
    Future<(ProviderContainer, FakeLocalSystem, FakeLocalHttp, Preferences)> setUpContainer({
      FakeLocalSystem? system,
      Map<String, LocalReply>? replies,
    }) async {
      final s = system ?? FakeLocalSystem();
      final http = FakeLocalHttp(replies);
      final prefs = Preferences.inMemory();
      final c = ProviderContainer(
        overrides: [
          localDetectionProvider.overrideWithValue(true),
          localSystemProvider.overrideWithValue(s),
          localHttpProvider.overrideWithValue(http),
          preferencesProvider.overrideWithValue(prefs),
          secretStoreProvider.overrideWithValue(_Store()),
        ],
      );
      addTearDown(c.dispose);
      c.listen(serverLifecyclesProvider, (_, _) {});
      await c.read(localServersProvider.future);
      await pumpEventQueue();
      return (c, s, http, prefs);
    }

    test("LM Studio's server starts detached (not through run); ownership comes after the port answers", () async {
      final system = FakeLocalSystem(lms: '/h/.lmstudio/bin/lms');
      final (c, _, http, _) = await setUpContainer(system: system);
      final lm = c.read(localServersProvider).value!.singleWhere((s) => s.id == 'lmstudio');
      final lifecycles = c.read(serverLifecyclesProvider.notifier);
      var answeredBeforeLaunch = false;
      system.onDetached = (_, _) {
        answeredBeforeLaunch = http.replies.containsKey('GET 127.0.0.1:1234/v1/models');
        Future<void>.delayed(const Duration(milliseconds: 400), () {
          http.replies['GET 127.0.0.1:1234/v1/models'] = json('{"data":[]}');
          http.replies['GET 127.0.0.1:1234/api/v0/models'] = json('{"data":[]}');
        });
      };
      expect(await lifecycles.start(lm), isNull);
      expect(answeredBeforeLaunch, isFalse);
      expect(system.detached, ['/h/.lmstudio/bin/lms server start --port 1234']);
      expect(system.ran, isEmpty);
      expect(c.read(serverLifecyclesProvider)['lmstudio'], const ServerRunning(ServerOwner.everyai));
    });

    test("a failed detached launch of LM Studio's server leaves ownership false", () async {
      final system = FakeLocalSystem(lms: '/h/.lmstudio/bin/lms')..detachedFails = 'no such file';
      final (c, _, _, _) = await setUpContainer(system: system);
      final lm = c.read(localServersProvider).value!.singleWhere((s) => s.id == 'lmstudio');
      final lifecycles = c.read(serverLifecyclesProvider.notifier);
      expect(await lifecycles.start(lm), contains('no such file'));
      expect(c.read(serverLifecyclesProvider)['lmstudio'], isNot(const ServerRunning(ServerOwner.everyai)));
      expect(system.ran, isEmpty);
    });

    test('a Stop before a start launched anything launches nothing and leaves the port alone', () async {
      final system = FakeLocalSystem(ollama: '/usr/bin/ollama');
      final (c, _, http, _) = await setUpContainer(system: system);
      system.logDirGate = Completer<void>();
      final ollama = c.read(localServersProvider).value!.single;
      final lifecycles = c.read(serverLifecyclesProvider.notifier);
      final starting = lifecycles.start(ollama);
      await pumpEventQueue();
      expect(c.read(serverLifecyclesProvider)['ollama'], const ServerStarting());
      final stopping = lifecycles.stop(ollama);
      system.logDirGate!.complete();
      expect(await stopping, isNull);
      await starting;
      expect(system.launches, isEmpty);
      expect(system.stoppedPorts, isEmpty);
      expect(c.read(serverLifecyclesProvider)['ollama'], const ServerStopped());

      // The start's end didn't drop the stop's entry, and a new start runs.
      system.logDirGate = null;
      system.onLaunch = (_, _) => http.replies['GET 127.0.0.1:11434/api/version'] = json('{"version":"1"}');
      expect(await lifecycles.start(ollama), isNull);
      expect(system.launches, ['ollama']);
    });

    test('a stop of our server that leaves it running ends NotClosed, and Stop again retries', () async {
      final system = FakeLocalSystem(ollama: '/usr/bin/ollama');
      final (c, _, http, _) = await setUpContainer(system: system);
      system.onLaunch = (_, _) => http.replies.addAll({
        'GET 127.0.0.1:11434/api/version': json('{"version":"1"}'),
        'GET 127.0.0.1:11434/api/tags': json('{"models":[]}'),
      });
      final ollama = c.read(localServersProvider).value!.single;
      final lifecycles = c.read(serverLifecyclesProvider.notifier);
      expect(await lifecycles.start(ollama), isNull);
      system.ownedStopResult = const ServerStopNotClosed(Survived([4242], 'still running after SIGKILL'));
      expect(await lifecycles.stop(ollama), contains('Not closed'));
      expect(c.read(serverLifecyclesProvider)['ollama'], isA<ServerNotClosed>());
      // A start is refused while it isn't closed.
      expect(await lifecycles.start(ollama), contains('did not close'));
      system.ownedStopResult = null;
      http.replies.clear();
      expect(await lifecycles.stop(ollama), isNull);
      expect(c.read(serverLifecyclesProvider)['ollama'], const ServerStopped());
    });

    test('quit stops only what EveryAI started', () async {
      final system = FakeLocalSystem(ollama: '/usr/bin/ollama');
      final (c, _, http, _) = await setUpContainer(system: system);
      system.onLaunch = (_, _) => http.replies['GET 127.0.0.1:11434/api/version'] = json('{"version":"1"}');
      final ollama = c.read(localServersProvider).value!.single;
      await c.read(serverLifecyclesProvider.notifier).start(ollama);
      await c.read(serverLifecyclesProvider.notifier).stopOwned();
      expect(system.owns('ollama'), isFalse);
      expect(system.stoppedPorts, isEmpty);
    });
  });

  group('quit', () {
    test('a bundled server that hangs still lets the model servers stop', () async {
      var stopped = false;
      final outcome = await localShutdown(
        closeBackend: () => Completer<KillOutcome>().future,
        stopServers: () async {
          stopped = true;
          return const Ended([1]);
        },
        closeWithin: const Duration(milliseconds: 50),
      );
      expect(stopped, isTrue);
      // The hang is an outcome, not dropped.
      expect(outcome, isA<ScanFailed>().having((o) => o.why, 'why', contains('did not finish')));
    });
  });

  group('listener checks', () {});

  group('shellStartCommand', () {});
}
