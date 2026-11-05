import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/features/code/drivers/detection/desktop_apps.dart';
import 'package:every_ai/features/code/drivers/driver.dart';
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/environments/exec_env.dart';
import 'package:every_ai/features/code/ui/harness_setup_row.dart';
import 'package:every_ai/features/code/ui/setup_button.dart';
import 'package:every_ai/features/onboarding/domain/harness_rows.dart';
import 'package:every_ai/features/onboarding/git_bash_stub.dart';
import 'package:every_ai/features/onboarding/onboarding_harness_providers.dart';
import 'package:every_ai/features/onboarding/ui/onboarding_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

import '../support/fake_leads.dart';
import '../support/fake_wsl_env.dart';

Future<AppScan> _noApps() async => const AppScan();

EnvStatus _on(String id, DriverStatus s, [ExecEnv env = HostEnv.instance]) => (env: env, driverId: id, status: s);

Widget _app(Widget home, {List<EnvStatus> found = const [], bool done = true, List<Override> extra = const []}) {
  return ProviderScope(
    key: UniqueKey(),
    overrides: [
      preferencesProvider.overrideWithValue(Preferences.inMemory()),
      driverRegistryProvider.overrideWithValue(
        DriverRegistry({
          'everyai': FakeLeadDriver('everyai', label: 'EveryAI'),
          'claude-code': FakeLeadDriver('claude-code', label: 'Claude Code', needsConsent: true),
          'codex': FakeLeadDriver('codex', label: 'Codex'),
          'opencode': FakeLeadDriver('opencode', label: 'OpenCode'),
        }),
      ),
      driverStatusesProvider.overrideWith(
        () => DriverStatuses(scanApps: _noApps, loadShell: () async {}, reloadShell: () async {}),
      ),
      harnessEnvStatusesProvider.overrideWithValue(found),
      harnessChecksDoneProvider.overrideWithValue(done),
      ...extra,
    ],
    child: m.MaterialApp(
      builder: (context, c) =>
          EveryThemeScope(theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light), child: c!),
      home: m.Scaffold(body: home),
    ),
  );
}

Future<void> _mac(WidgetTester tester, Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

Future<void> _toHarnessStep(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1000, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  for (var i = 0; i < 3; i++) {
    await tester.tap(find.byKey(const ValueKey('onboarding.next')));
    await tester.pumpAndSettle();
  }
  expect(find.text('Code works with the agents you already use.'), findsOneWidget);
}

void main() {
  testWidgets('the setup step: ready shows a mark, signed out Sign in, absent is hidden, consent stays', (
    tester,
  ) async {
    await _mac(tester, () async {
      final opened = <String>[];
      await tester.pumpWidget(
        _app(
          const OnboardingScreen(desktop: true),
          found: [
            _on('claude-code', const DriverStatus(installed: true, version: '2.1', signedIn: false)),
            _on('codex', const DriverStatus(installed: true, version: '0.9', signedIn: true)),
            _on('opencode', const DriverStatus()),
          ],
          extra: [setupOpenerProvider.overrideWithValue((context, driver, env) async => opened.add(driver.info.id))],
        ),
      );
      await tester.pumpAndSettle();
      await _toHarnessStep(tester);

      expect(find.byKey(const ValueKey('onboarding.harness.everyai')), findsOneWidget);
      expect(find.byKey(const ValueKey('harness.ready.codex')), findsOneWidget);
      expect(find.byKey(const ValueKey('setup.codex')), findsNothing);
      expect(find.byKey(const ValueKey('onboarding.harness.opencode')), findsNothing);
      // Signed out is not ready: Sign in, but only once the subscription CLI is allowed.
      expect(find.byKey(const ValueKey('harness.ready.claude-code')), findsNothing);
      expect(find.byKey(const ValueKey('setup.claude-code')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('onboarding.consent.claude-code')));
      await tester.pumpAndSettle();
      expect(find.text('In use ✓'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('setup.claude-code')));
      expect(opened, ['claude-code']);
      expect(find.byKey(const ValueKey('onboarding.import')), findsOneWidget);
    });
  });

  testWidgets('nothing found: a plain line instead of an empty list', (tester) async {
    await _mac(tester, () async {
      await tester.pumpWidget(
        _app(
          const OnboardingScreen(desktop: true),
          found: [
            for (final id in ['claude-code', 'codex', 'opencode']) _on(id, const DriverStatus()),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await _toHarnessStep(tester);
      expect(find.byKey(const ValueKey('onboarding.none-found')), findsOneWidget);
      expect(find.byKey(const ValueKey('onboarding.harness.codex')), findsNothing);
    });
  });

  testWidgets('a harness in another environment names it', (tester) async {
    await _mac(tester, () async {
      await tester.pumpWidget(
        _app(
          const OnboardingScreen(desktop: true),
          found: [_on('codex', const DriverStatus(installed: true), const FakeWslEnv())],
        ),
      );
      await tester.pumpAndSettle();
      await _toHarnessStep(tester);
      expect(find.text('Codex · Ubuntu (WSL)'), findsOneWidget);
    });
  });

  testWidgets('the Git for Windows notice shows only when Git is missing, and Set up is the bound action', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      _app(
        const m.SingleChildScrollView(child: GitForWindowsNotice()),
        extra: [gitBashMissingProvider.overrideWithValue(false)],
      ),
    );
    expect(find.byKey(const ValueKey('harness.git-for-windows')), findsNothing);

    await tester.pumpWidget(
      _app(
        const m.SingleChildScrollView(child: GitForWindowsNotice()),
        extra: [gitBashMissingProvider.overrideWithValue(true)],
      ),
    );
    expect(find.textContaining('needs Git for Windows'), findsOneWidget);
    expect(find.text('To install: $gitForWindowsInstallLine'), findsOneWidget);
    expect(find.byKey(const ValueKey('harness.git-for-windows.setup')), findsNothing);

    await tester.pumpWidget(
      _app(
        const m.SingleChildScrollView(child: GitForWindowsNotice()),
        extra: [
          gitBashMissingProvider.overrideWithValue(true),
          gitForWindowsSetUpProvider.overrideWithValue(() => calls++),
        ],
      ),
    );
    await tester.tap(find.byKey(const ValueKey('harness.git-for-windows.setup')));
    expect(calls, 1);
  });
}
