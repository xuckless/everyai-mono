import 'dart:async';
import 'dart:convert';

import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/code_settings_providers.dart';
import 'package:every_ai/features/code/drivers/detection/desktop_apps.dart';
import 'package:every_ai/features/code/drivers/driver.dart';
import 'package:every_ai/features/code/drivers/driver_process.dart' show noAnswerProblem;
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/environments/exec_env.dart';
import 'package:every_ai/core/process/supervisor.dart' show Ended, SupervisedChild;
import 'package:every_ai/features/code/panes/pty.dart';
import 'package:every_ai/features/code/panes/setup_terminal.dart';
import 'package:every_ai/features/code/ui/setup_button.dart';
import 'package:every_ai/features/code/ui/setup_terminal_dialog.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

import '../../../support/fake_leads.dart';

final class _Pty implements ShellPty {
  final writes = <String>[];
  var kills = 0;
  @override
  int get pid => 1;
  @override
  Stream<Uint8List> get output => const Stream.empty();
  @override
  Future<int> get exitCode => Completer<int>().future;
  @override
  void write(Uint8List data) => writes.add(utf8.decode(data));
  @override
  void resize(int rows, int columns) {}
  @override
  Future<KillOutcome> kill() async {
    kills++;
    return const Ended([]);
  }

  @override
  SupervisedChild get child => throw UnimplementedError('not supervised (a fake)');
}

Future<AppScan> _noApps() async => const AppScan();

Widget _app(
  Widget home, {
  required FakeLeadDriver driver,
  required List<Override> extra,
  required void Function(int) onReload,
}) {
  return ProviderScope(
    overrides: [
      preferencesProvider.overrideWithValue(Preferences.inMemory()),
      driverRegistryProvider.overrideWithValue(DriverRegistry({driver.id: driver})),
      driverStatusesProvider.overrideWith(() {
        var reloads = 0;
        return DriverStatuses(scanApps: _noApps, loadShell: () async {}, reloadShell: () async => onReload(++reloads));
      }),
      setupSettleProvider.overrideWithValue(() async {}),
      ...extra,
    ],
    child: m.MaterialApp(
      builder: (context, c) =>
          EveryThemeScope(theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light), child: c!),
      home: m.Scaffold(body: home),
    ),
  );
}

/// Runs [body] as [platform]; the override is cleared before the binding checks its debug variables.
Future<void> Function(WidgetTester) _on(TargetPlatform platform, Future<void> Function(WidgetTester) body) =>
    (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    };

Future<void> Function(WidgetTester) _mac(Future<void> Function(WidgetTester) body) => _on(TargetPlatform.macOS, body);

void main() {
  group('SetupButton', () {
    Future<void> pumpButton(
      WidgetTester tester,
      FakeLeadDriver d, {
      DriverStatus? status,
      bool consented = false,
      List<(String, ExecEnv)>? opened,
    }) async {
      await tester.pumpWidget(
        _app(
          Consumer(
            builder: (context, ref, _) => SetupButton(driver: d, status: status),
          ),
          driver: d,
          onReload: (_) {},
          extra: [
            if (opened != null)
              setupOpenerProvider.overrideWithValue(
                (context, driver, env, {signIn = false}) async => opened.add((driver.info.id, env)),
              ),
          ],
        ),
      );
      if (consented) {
        ProviderScope.containerOf(tester.element(find.byType(SetupButton)))
            .read(codeSettingsProvider.notifier)
            .setOwnCli(d.info.consentId, true);
        await tester.pump();
      }
    }

    testWidgets(
      'Set up for a missing CLI, and a tap opens the terminal with the driver and environment',
      _mac((tester) async {
        final opened = <(String, ExecEnv)>[];
        await pumpButton(tester, FakeLeadDriver('codex'), status: const DriverStatus(), opened: opened);
        expect(find.text('Set up'), findsOneWidget);
        await tester.tap(find.text('Set up'));
        expect(opened, [('codex', HostEnv.instance)]);
      }),
    );

    testWidgets(
      'a check that failed is not a missing CLI: no Set up on a guess',
      _mac((tester) async {
        for (final problem in [noAnswerProblem, "Couldn't check: boom"]) {
          await pumpButton(tester, FakeLeadDriver('codex'), status: DriverStatus(problem: problem));
          expect(find.text('Set up'), findsNothing);
        }
        // A CLI that is there but broken is still offered a fix.
        await pumpButton(
          tester,
          FakeLeadDriver('codex'),
          status: const DriverStatus(installed: true, path: '/bin/codex', problem: 'Too old'),
        );
        expect(find.text('Set up'), findsOneWidget);
      }),
    );

    testWidgets(
      'onboarding offers a missing CLI only where the vendor app was found',
      _mac((tester) async {
        final d = FakeLeadDriver('codex');
        await tester.pumpWidget(
          _app(
            SetupButton(driver: d, status: const DriverStatus(), offerMissing: false),
            driver: d,
            onReload: (_) {},
            extra: [],
          ),
        );
        await tester.pump();
        expect(find.text('Set up'), findsNothing);
      }),
    );

    testWidgets(
      'Sign in for a CLI that says it is signed out',
      _mac((tester) async {
        await pumpButton(
          tester,
          FakeLeadDriver('codex'),
          status: const DriverStatus(installed: true, path: '/bin/codex', signedIn: false),
        );
        expect(find.text('Sign in'), findsOneWidget);
      }),
    );

    testWidgets(
      'nothing for a ready CLI, a running check, the own harness or a CLI with no line',
      _mac((tester) async {
        await pumpButton(tester, FakeLeadDriver('codex'), status: const DriverStatus(installed: true, signedIn: true));
        expect(find.byType(m.FilledButton), findsNothing);
        await pumpButton(tester, FakeLeadDriver('codex'), status: null);
        expect(find.text('Set up'), findsNothing);
        await pumpButton(tester, FakeLeadDriver('everyai'), status: const DriverStatus());
        expect(find.text('Set up'), findsNothing);
        await pumpButton(tester, FakeLeadDriver('added-by-hand'), status: const DriverStatus());
        expect(find.text('Set up'), findsNothing);
      }),
    );

    testWidgets(
      'nothing where there is no terminal (a phone)',
      _on(TargetPlatform.iOS, (tester) async {
        await pumpButton(tester, FakeLeadDriver('codex'), status: const DriverStatus());
        expect(find.text('Set up'), findsNothing);
      }),
    );

    testWidgets(
      'a subscription CLI waits for the user to agree to use it',
      _mac((tester) async {
        final d = FakeLeadDriver('claude-code', needsConsent: true);
        await pumpButton(tester, d, status: const DriverStatus());
        expect(find.text('Set up'), findsNothing);
        await pumpButton(tester, d, status: const DriverStatus(), consented: true);
        expect(find.text('Set up'), findsOneWidget);
      }),
    );
  });

  group('SetupTerminalDialog', () {
    testWidgets(
      'types the install line, checks again with a reload, and types the sign-in with the found path',
      _mac((tester) async {
        tester.view.physicalSize = const Size(1000, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final pty = _Pty();
        var reloads = 0;
        final d = FakeLeadDriver('claude-code', status: const DriverStatus());
        ExecEnv? seen;
        await tester.pumpWidget(
          _app(
            SetupTerminalDialog(driver: d, env: HostEnv.instance),
            driver: d,
            onReload: (n) => reloads = n,
            extra: [
              setupShellStarterProvider.overrideWithValue((env, home, rows, columns) async {
                seen = env;
                return pty;
              }),
            ],
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(seen, HostEnv.instance);
        expect(pty.writes.single, 'curl -fsSL https://claude.ai/install.sh | bash');
        expect(find.byKey(const ValueKey('setup.command')), findsOneWidget);
        expect(find.byKey(const ValueKey('setup.sign-in')), findsNothing);

        // The install ran; the CLI is there but signed out.
        d.status = const DriverStatus(installed: true, path: '/Users/a b/.local/bin/claude', signedIn: false);
        await tester.tap(find.byKey(const ValueKey('setup.check')));
        await tester.pump();
        await tester.pump();
        expect(reloads, 1);
        await tester.tap(find.byKey(const ValueKey('setup.sign-in')));
        expect(pty.writes.last, "'/Users/a b/.local/bin/claude' auth login");
        expect(pty.writes.last, isNot(contains('\n')));

        d.status = const DriverStatus(installed: true, path: '/x/claude', signedIn: true);
        await tester.tap(find.byKey(const ValueKey('setup.check')));
        await tester.pump();
        await tester.pump();
        expect(find.textContaining('Ready'), findsOneWidget);
        expect(find.byKey(const ValueKey('setup.sign-in')), findsNothing);

        await tester.tap(find.byKey(const ValueKey('setup.done')));
        await tester.pump();
        expect(pty.kills, 1);
        expect(reloads, 3);
      }),
    );

    testWidgets(
      'opened for sign-in, it types the login command with the found path, not the install line',
      _mac((tester) async {
        tester.view.physicalSize = const Size(1000, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final pty = _Pty();
        final d = FakeLeadDriver(
          'claude-code',
          label: 'Claude Code',
          status: const DriverStatus(installed: true, path: '/x/claude', signedIn: false),
        );
        await tester.pumpWidget(
          _app(
            // Built once the first check has an answer, as the row's button only shows after it.
            Consumer(
              builder: (context, ref, _) => ref.watch(driverStatusesProvider).hasValue
                  ? SetupTerminalDialog(driver: d, env: HostEnv.instance, signIn: true)
                  : const SizedBox.shrink(),
            ),
            driver: d,
            onReload: (_) {},
            extra: [setupShellStarterProvider.overrideWithValue((env, home, rows, columns) async => pty)],
          ),
        );
        await tester.pump();
        await tester.pump();
        await tester.pump();
        expect(pty.writes.single, '/x/claude auth login');
        expect(find.byKey(const ValueKey('setup.command')), findsNothing);
        expect(find.text('Sign in to Claude Code'), findsOneWidget);
      }),
    );

    testWidgets(
      'inside another environment on Windows: the Linux line, no host check, no Sign in',
      _on(TargetPlatform.windows, (tester) async {
        tester.view.physicalSize = const Size(1000, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final pty = _Pty();
        // The host check finds a signed-out Windows CLI; it must not leak into the distro.
        final d = FakeLeadDriver(
          'codex',
          status: const DriverStatus(installed: true, path: r'C:\Users\a\codex.exe', signedIn: false),
        );
        await tester.pumpWidget(
          _app(
            SetupTerminalDialog(driver: d, env: _Wsl()),
            driver: d,
            onReload: (_) {},
            extra: [setupShellStarterProvider.overrideWithValue((env, home, rows, columns) async => pty)],
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(pty.writes.single, 'curl -fsSL https://chatgpt.com/codex/install.sh | sh');
        expect(find.byKey(const ValueKey('setup.check')), findsNothing);
        expect(find.byKey(const ValueKey('setup.sign-in')), findsNothing);
      }),
    );

    testWidgets(
      'names the environment when it is not this computer',
      _mac((tester) async {
        tester.view.physicalSize = const Size(1000, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final d = FakeLeadDriver('codex', status: const DriverStatus());
        await tester.pumpWidget(
          _app(
            SetupTerminalDialog(driver: d, env: _Wsl()),
            driver: d,
            onReload: (_) {},
            extra: [setupShellStarterProvider.overrideWithValue((env, home, rows, columns) async => _Pty())],
          ),
        );
        await tester.pump();
        expect(find.text('Inside: Ubuntu (WSL)'), findsOneWidget);
      }),
    );
  });
}

final class _Wsl extends ExecEnv {
  @override
  String get id => 'wsl:Ubuntu';
  @override
  EnvKind get kind => EnvKind.wsl;
  @override
  String get label => 'Ubuntu (WSL)';
  @override
  WrappedCommand wrap(String executable, List<String> args, {String? cwd, Map<String, String> env = const {}}) =>
      (executable: executable, args: args, environment: const {});
  @override
  String? toEnvPath(String hostPath) => null;
  @override
  String? toHostPath(String envPath) => null;
}
