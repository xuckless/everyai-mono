import 'package:every_ai/core/local_backend/local_backend.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/process/process_model.dart' show Ended, KillOutcome, ScanFailed, Survived;
import 'package:every_ai/features/local_models/data/local_system.dart';
import 'package:every_ai/features/local_models/data/local_http.dart';
import 'package:every_ai/features/code/gateway_key.dart';

import 'dart:async';

import 'package:every_ai/features/local_models/data/local_system_io.dart' show shellStartCommand;
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
    const theirs = ServerRunning(ServerOwner.outside);

    test('start, run, stop', () {
      expect(nextPhase(stopped, const StartAsked()), starting);
      expect(nextPhase(starting, const Started(ServerOwner.everyai)), ours);
      expect(nextPhase(ours, const StopAsked()), const ServerStopping(ServerOwner.everyai));
      expect(nextPhase(const ServerStopping(ServerOwner.everyai), const StopDone()), stopped);
    });

    test('failures keep their reason; a failed stop goes back to who ran it', () {
      expect(nextPhase(starting, const StartFailed('no port')), const ServerFailed('no port'));
      expect(nextPhase(const ServerFailed('no port'), const StartAsked()), starting);
      expect(nextPhase(const ServerStopping(ServerOwner.outside), const StopFailed('denied')), theirs);
    });

    test("scans don't interrupt an action, and find servers started elsewhere", () {
      expect(nextPhase(starting, const SeenDown()), starting);
      expect(
        nextPhase(const ServerStopping(ServerOwner.everyai), const SeenUp(ServerOwner.everyai)),
        const ServerStopping(ServerOwner.everyai),
      );
      expect(nextPhase(stopped, const SeenUp(ServerOwner.outside)), theirs);
      expect(nextPhase(theirs, const SeenDown()), stopped);
    });

    test('a stop that signalled but did not end it is NotClosed until a retry or its seen end', () {
      const stopping = ServerStopping(ServerOwner.everyai);
      const notClosed = ServerNotClosed(ServerOwner.everyai, 'pid 5 survived');
      expect(nextPhase(stopping, const StopNotClosed('pid 5 survived')), notClosed);
      // A scan that no longer gets an answer doesn't make it closed.
      expect(nextPhase(notClosed, const SeenDown()), notClosed);
      expect(nextPhase(notClosed, const SeenUp(ServerOwner.everyai)), notClosed);
      expect(nextPhase(notClosed, const StartAsked()), isNull);
      expect(nextPhase(notClosed, const StopAsked()), stopping);
      expect(nextPhase(notClosed, const ProcessGone()), stopped);
      expect(nextPhase(ours, const ProcessGone()), stopped);
    });

    test('a refused move is recorded (and asserts in debug)', () {
      assertOnRefusedServerTransition = false;
      addTearDown(() => assertOnRefusedServerTransition = true);
      refusedServerTransitions.clear();
      expect(applyServerEvent('x', stopped, const StopDone()), isNull);
      expect(refusedServerTransitions.single.server, 'x');
    });

    test('impossible events are refused', () {
      expect(nextPhase(stopped, const StopAsked()), isNull);
      expect(nextPhase(ours, const StartAsked()), isNull);
      expect(nextPhase(stopped, const Started(ServerOwner.everyai)), isNull);
      expect(nextPhase(ours, const StopDone()), isNull);
    });
  });

  group('bundled server phases', () {
    test('start, crash, restart, stop', () {
      expect(nextBackendPhase(const BackendIdle(), const BackendStartAsked()), isA<BackendStarting>());
      expect(nextBackendPhase(const BackendStarting(), BackendReady(_info)), isA<BackendRunning>());
      expect(nextBackendPhase(BackendRunning(_info), const BackendExited('exit 1')), isA<BackendCrashed>());
      expect(nextBackendPhase(const BackendCrashed('exit 1'), const BackendStartAsked()), isA<BackendStarting>());
      expect(nextBackendPhase(BackendRunning(_info), const BackendStopAsked()), isA<BackendStopping>());
      expect(nextBackendPhase(const BackendStopping(), const BackendExited('ok')), isA<BackendIdle>());
    });

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

    test('a server started outside EveryAI is Running(outside); Stop ends what listens on its port', () async {
      final (c, system, http, _) = await setUpContainer(
        replies: {'GET 127.0.0.1:1234/api/v0/models': json('{"data":[]}')},
      );
      final lms = c.read(localServersProvider).value!.single;
      expect(c.read(serverLifecyclesProvider.notifier).phaseOf(lms), const ServerRunning(ServerOwner.outside));
      // No `lms` installed: the listener is stopped.
      http.replies.clear();
      expect(await c.read(serverLifecyclesProvider.notifier).stop(lms), isNull);
      expect(system.stoppedPorts, [1234]);
      expect(c.read(serverLifecyclesProvider)['lmstudio'], const ServerStopped());
    });

    test('a stop that fails says why and leaves it running', () async {
      final system = FakeLocalSystem()..listenerStopProblem = "EveryAI isn't allowed to stop it.";
      final (c, _, _, _) = await setUpContainer(
        system: system,
        replies: {'GET 127.0.0.1:1234/api/v0/models': json('{"data":[]}')},
      );
      final lms = c.read(localServersProvider).value!.single;
      expect(await c.read(serverLifecyclesProvider.notifier).stop(lms), "EveryAI isn't allowed to stop it.");
      expect(c.read(serverLifecyclesProvider)['lmstudio'], const ServerRunning(ServerOwner.outside));
    });

    test('two Starts at once launch once; a server that exits is seen down', () async {
      final system = FakeLocalSystem(ollama: '/usr/bin/ollama');
      final (c, _, http, _) = await setUpContainer(system: system);
      system.onLaunch = (_, _) => http.replies.addAll({
        'GET 127.0.0.1:11434/api/version': json('{"version":"0.21.0"}'),
        'GET 127.0.0.1:11434/api/tags': json('{"models":[]}'),
      });
      final ollama = c.read(localServersProvider).value!.single;
      final lifecycles = c.read(serverLifecyclesProvider.notifier);
      final a = lifecycles.start(ollama);
      final b = lifecycles.start(ollama);
      expect(await a, isNull);
      expect(await b, isNull);
      expect(system.ollamaStarts, 1);
      expect(c.read(serverLifecyclesProvider)['ollama'], const ServerRunning(ServerOwner.everyai));

      system.launched['ollama']!.complete(1);
      await pumpEventQueue();
      expect(c.read(serverLifecyclesProvider)['ollama'], const ServerStopped());
    });

    test("Apple's server starts by itself until the user stops it", () async {
      final system = FakeLocalSystem(fm: const FmStatus(FmState.ready), fmPort: 4567);
      system.onLaunch = (_, _) {};
      final (c, _, http, prefs) = await setUpContainer(system: system);
      http.replies['GET 127.0.0.1:4567/health'] = json('{"status":"ok"}');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(system.launches, ['fm']);
      final fm = (await c.read(localServersProvider.future)).firstWhere((s) => s.id == 'fm');
      http.replies.clear();
      expect(await c.read(serverLifecyclesProvider.notifier).stop(fm), isNull);
      expect(prefs[ServerLifecycles.fmAutostartKey], '0');
      expect(system.owns('fm'), isFalse);
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

    test('a Stop while the server comes up ends what the start launched', () async {
      final system = FakeLocalSystem(ollama: '/usr/bin/ollama');
      final (c, _, _, _) = await setUpContainer(system: system);
      final ollama = c.read(localServersProvider).value!.single;
      final lifecycles = c.read(serverLifecyclesProvider.notifier);
      final starting = lifecycles.start(ollama);
      // Launched, but it never answers.
      while (system.launches.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(await lifecycles.stop(ollama), isNull);
      await starting;
      expect(system.owns('ollama'), isFalse);
      expect(c.read(serverLifecyclesProvider)['ollama'], const ServerStopped());
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

    test('removing a running manual server stops it first; one that does not stop stays', () async {
      final system = FakeLocalSystem();
      final (c, _, http, _) = await setUpContainer(system: system);
      final added = await c
          .read(manualServersProvider.notifier)
          .add(baseUrl: 'http://127.0.0.1:8080/v1', startCommand: 'llama-server -m /m.gguf --port 8080');
      system.onLaunch = (_, _) => http.replies['GET 127.0.0.1:8080/v1/models'] = json('{"data":[]}');
      final server = (await c.read(localServersProvider.future)).firstWhere((s) => s.id == added!.id);
      expect(await c.read(serverLifecyclesProvider.notifier).start(server), isNull);
      await c.read(localServersProvider.notifier).refresh();
      system.ownedStopResult = const ServerStopNotClosed(Survived([7], 'still running after SIGKILL'));
      expect(await c.read(manualServersProvider.notifier).remove(server.id), contains("wasn't removed"));
      expect(c.read(manualServersProvider).map((s) => s.id), [server.id]);
      system.ownedStopResult = null;
      expect(await c.read(manualServersProvider.notifier).remove(server.id), isNull);
      expect(system.owns(server.id), isFalse);
      expect(c.read(manualServersProvider), isEmpty);
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

    test('a bundled server that fails still lets the model servers stop', () async {
      var stopped = false;
      final outcome = await localShutdown(
        closeBackend: () async => throw StateError('gone'),
        stopServers: () async {
          stopped = true;
          return const Ended([]);
        },
      );
      expect(stopped, isTrue);
      expect(outcome, isA<ScanFailed>());
    });

    test('a clean quit is Ended with what both steps ended', () async {
      final outcome = await localShutdown(
        closeBackend: () async => const Ended([1]),
        stopServers: () async => const Ended([2]),
      );
      expect(outcome, isA<Ended>().having((o) => o.pids, 'pids', [1, 2]));
    });
  });

  group('listener checks', () {
    LocalServer server(LocalServerKind kind, {String url = 'http://127.0.0.1:11434/v1', String? start}) =>
        LocalServer(id: kind.name, kind: kind, label: kind.label, baseUrl: url, startCommand: start);

    test('loopback addresses only', () {
      expect(isLoopbackUrl('http://127.0.0.1:1/v1'), isTrue);
      expect(isLoopbackUrl('http://localhost:1/v1'), isTrue);
      expect(isLoopbackUrl('http://[::1]:1/v1'), isTrue);
      expect(isLoopbackUrl('http://192.168.1.4:11434/v1'), isFalse);
      expect(isLoopbackUrl('http://gpu-box.local:8000/v1'), isFalse);
    });

    test("a listener counts only when it is the server's kind of program", () {
      expect(listenerMatches(server(LocalServerKind.ollama), '/usr/local/bin/ollama serve'), isTrue);
      expect(listenerMatches(server(LocalServerKind.ollama), '/usr/bin/python3 -m http.server 11434'), isFalse);
      expect(
        listenerMatches(server(LocalServerKind.lmstudio), '/Applications/LM Studio.app/Contents/MacOS/LM Studio'),
        isTrue,
      );
      expect(listenerMatches(server(LocalServerKind.llamacpp), '/opt/llama.cpp/build/bin/llama-server -m x'), isTrue);
      final manual = server(LocalServerKind.custom, start: 'CUDA=1 exec /opt/bin/my-server --port 9000');
      expect(startCommandProgram('CUDA=1 exec /opt/bin/my-server --port 9000'), 'my-server');
      expect(listenerMatches(manual, '/opt/bin/my-server --port 9000'), isTrue);
      expect(listenerMatches(manual, '/usr/bin/node other.js'), isFalse);
      expect(listenerMatches(server(LocalServerKind.custom), '/opt/bin/my-server'), isFalse);
    });
  });

  group('shellStartCommand', () {
    test('a single command is exec-ed so the server takes the shell pid', () {
      expect(shellStartCommand('llama-server -m /m.gguf --port 8080'), 'exec llama-server -m /m.gguf --port 8080');
      expect(shellStartCommand('exec foo'), 'exec foo');
    });

    test('shell syntax is left alone', () {
      for (final c in ['cd /x && ./serve', 'a; b', 'a | b', 'a &', 'PORT=1 serve', r'serve $(cat p)', 'export A=1']) {
        expect(shellStartCommand(c), c);
      }
    });
  });
}
