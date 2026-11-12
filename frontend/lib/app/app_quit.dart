import 'dart:async';
import 'dart:io' show Platform, ProcessSignal, exit;
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb, visibleForTesting;
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/local_backend/local_backend_providers.dart';
import '../core/process/supervisor.dart';
import '../features/code/code_providers.dart' show codeSessionProvider, codeSessionsProvider;
import '../features/code/drivers/driver_process.dart' show closeAllDriverProcesses;
import '../features/code/harness/everyai/everyai.dart' show closeAllLanguageServers;
import '../features/code/host/host_providers.dart' show hostServerProvider;
import '../features/code/live/android_device_io.dart' show AndroidDevices;
import '../features/code/live/app_sources.dart' show AppSources;
import '../features/code/live/ios_simulator_io.dart' show IosSimulators;
import '../features/code/live/live_browsers.dart' show LiveBrowsers;
import '../features/code/live/nested_display_io.dart' show NestedDisplays;
import '../features/local_models/local_models_providers.dart' show serverLifecyclesProvider;

/// One step of the quit before the supervisor ends what is left: what it ended, within its own bound.
typedef QuitStep = ({String name, Duration within, Future<KillOutcome> Function() run});

/// What a quit did: each step's outcome, in order, and the supervisor's report (also in `quit.json`).
final class AppQuitReport {
  const AppQuitReport(this.steps, this.supervisor);
  final List<(String, KillOutcome)> steps;
  final QuitReport supervisor;

  bool get clean => supervisor.clean && steps.every((s) => s.$2 is Ended);
}

/// The one quit sequence: [steps] in order, each awaited within its bound (a step past it, or one that throws, is a
/// not-closed outcome: logged, never dropped; what it started is still ended by the supervisor's pass), then
/// [ProcessSupervisor.stopAll] ends every child left and writes `quit.json`.
Future<AppQuitReport> runQuit(ProcessSupervisor supervisor, List<QuitStep> steps) async {
  final results = <(String, KillOutcome)>[];
  Future<void> Function() bounded(QuitStep s) => () async {
    KillOutcome outcome;
    try {
      outcome = await s.run().timeout(s.within);
    } on TimeoutException {
      outcome = ScanFailed('${s.name} did not finish within ${s.within.inMilliseconds} ms');
    } on Object catch (e) {
      outcome = ScanFailed('${s.name} failed: $e');
    }
    results.add((s.name, outcome));
    debugPrint(outcome is Ended ? 'Quit: ${s.name}: ended' : 'NOT CLOSED: quit step ${s.name}: $outcome');
  };
  final report = await supervisor.stopAll(before: [for (final s in steps) bounded(s)]);
  for (final e in report.entries) {
    if (e.outcome is! Ended) debugPrint('NOT CLOSED at quit: $e');
  }
  return AppQuitReport(results, report);
}

Future<KillOutcome> _ended(Future<void> f) async {
  await f;
  return const Ended([]);
}

/// The app's quit (desktop): the steps in their order, run once however the app ends (quit, the engine detaching,
/// SIGTERM).
final class AppQuit {
  AppQuit(this._ref);
  final Ref _ref;
  Future<AppQuitReport>? _running;

  /// Replaces the supervisor's quit in tests.
  @visibleForTesting
  static ProcessSupervisor Function() supervisor = () => ProcessSupervisor.instance;

  /// One quit at a time; one that failed (threw) isn't kept, so the next ask runs it again.
  Future<AppQuitReport> quit() {
    final running = _running;
    if (running != null) return running;
    final f = runQuit(supervisor(), steps());
    _running = f;
    f.then(
      (_) {},
      onError: (Object e) {
        debugPrint('NOT CLOSED: the quit failed: $e');
        if (identical(_running, f)) _running = null;
      },
    );
    return f;
  }

  List<QuitStep> steps() {
    const short = Duration(seconds: 3);
    return [
      (
        name: "stopping the sessions' runs",
        within: short,
        run: () async {
          final ref = _ref;
          final open = [
            for (final s in ref.read(codeSessionsProvider))
              if (s.parentId == null && ref.exists(codeSessionProvider(s.id))) s.id,
          ];
          return KillOutcome.merge(
            await Future.wait([for (final id in open) ref.read(codeSessionProvider(id).notifier).stopAll()]),
          );
        },
      ),
      (name: 'closing the outside CLIs', within: short, run: closeAllDriverProcesses),
      // The browsers' jars (sign-ins) are read from the running Chrome before it stops.
      (name: 'saving sign-ins and stopping the browsers', within: short, run: LiveBrowsers.stopAllBrowsers),
      (name: 'stopping app runs', within: short, run: () => _ended(AppSources.stopAll())),
      (name: 'stopping Android devices', within: short, run: AndroidDevices.stopAll),
      (name: 'shutting down simulators', within: const Duration(seconds: 6), run: IosSimulators.shutdownBooted),
      (name: 'stopping displays', within: short, run: NestedDisplays.stopAll),
      (name: 'closing language servers', within: short, run: () => _ended(closeAllLanguageServers())),
      (
        name: 'closing the bundled server',
        within: const Duration(seconds: 4),
        run: () => _ref.read(localBackendProvider).close(unloadWithin: const Duration(milliseconds: 2500)),
      ),
      (
        name: 'stopping local model servers',
        within: const Duration(seconds: 4),
        run: () => _ref.read(serverLifecyclesProvider.notifier).stopOwned(),
      ),
      (
        name: 'stopping the host server',
        within: const Duration(seconds: 1),
        run: () => _ended(_ref.read(hostServerProvider).stop()),
      ),
    ];
  }
}

/// Listened to from app start (desktop): sweeps what an earlier run left, and quits through [AppQuit] on quit,
/// detach and SIGTERM.
final appQuitProvider = Provider<AppQuit>((ref) {
  final quit = AppQuit(ref);
  // At start, not at the first spawn: its report stays readable in `lastSweep`.
  ProcessSupervisor.instance.sweepPreviousRuns().then(
    (r) => debugPrint('Launch sweep: $r'),
    onError: (Object e) => debugPrint('Launch sweep failed: $e'),
  );
  final lifecycle = AppLifecycleListener(
    // Always lets the app quit: a quit that failed is logged (the supervisor's ledger keeps what is left for the
    // next launch's sweep).
    onExitRequested: () async {
      try {
        await quit.quit();
      } on Object catch (e) {
        debugPrint('NOT CLOSED: the quit failed: $e');
      }
      return AppExitResponse.exit;
    },
    // The engine is going away: the same sequence, as far as it gets (its steps log their outcomes).
    onDetach: () => quit.quit().ignore(),
  );
  StreamSubscription<ProcessSignal>? term;
  if (!kIsWeb && !Platform.isWindows) {
    term = ProcessSignal.sigterm.watch().listen((_) async {
      try {
        final report = await quit.quit();
        exit(report.clean ? 0 : 1);
      } on Object catch (e) {
        debugPrint('NOT CLOSED: the quit failed: $e');
        exit(1);
      }
    });
  }
  ref.onDispose(() {
    lifecycle.dispose();
    term?.cancel();
  });
  return quit;
});
