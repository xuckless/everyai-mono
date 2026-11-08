// The Preview pane mounting with the session's browser already there (the agent opened a page first): it must not
// read TickerMode (an inherited widget) from initState or from callbacks, only from didChangeDependencies. It used to
// assert "dependOnInheritedWidgetOfExactType<_EffectiveTickerMode>() ... before _PreviewPaneState.initState()
// completed", then "Looking up a deactivated widget's ancestor is unsafe" from its page listener.

import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/harness/everyai/browser_io.dart';
import 'package:every_ai/features/code/live/android_device_io.dart';
import 'package:every_ai/features/code/live/ios_simulator_io.dart';
import 'package:every_ai/features/code/live/live_browsers.dart';
import 'package:every_ai/features/code/ui/panes/preview_pane.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

void main() {
  final session = CodeSessionInfo(
    id: 'preview-mount',
    projectId: 'p',
    title: 't',
    conversationId: 'c',
    model: 'm',
    mode: AgentMode.ask,
    workingDir: '/w',
    createdAt: DateTime(2026),
  );

  // The pane's device scans (simctl, adb) keep their last read for 2 s: read them now, in real time, so the pane's
  // scans in the test's fake time answer from it instead of starting processes.
  setUp(() async {
    await IosSimulators.refresh(every: Duration.zero);
    await AndroidDevices.refresh(every: Duration.zero);
  });
  setUp(() => LiveBrowsers.debugSet(session.id, HeadlessBrowser(profileDir: '/nonexistent/preview-mount')));
  tearDown(() => LiveBrowsers.debugSet(session.id, null));

  Widget host({required bool shown, required bool swapped}) => ProviderScope(
    overrides: [preferencesProvider.overrideWithValue(Preferences.inMemory({}))],
    child: m.MaterialApp(
      builder: (context, c) =>
          EveryThemeScope(theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light), child: c!),
      home: m.Material(
        child: SizedBox(
          width: 900,
          height: 600,
          // As the console holds it: built once, then hidden with Offstage + TickerMode beside another view.
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (swapped) const SizedBox(key: ValueKey('other')),
              Offstage(
                key: const ValueKey('console.preview'),
                offstage: !shown,
                child: TickerMode(
                  enabled: shown,
                  child: PreviewPane(session: session),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  testWidgets('mounts with a browser already there, hides, shows and moves without reading TickerMode early', (
    tester,
  ) async {
    await tester.pumpWidget(host(shown: true, swapped: false));
    expect(tester.takeException(), isNull);
    // The page changes while the pane is hidden and while it moves in the stack: its listener reads [_visible].
    final browser = LiveBrowsers.of(session.id)!;
    for (final (shown, swapped) in [(false, false), (false, true), (true, true), (true, false)]) {
      await tester.pumpWidget(host(shown: shown, swapped: swapped));
      browser.page.value = browser.page.value;
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'shown $shown, moved $swapped');
    }
    await tester.pumpWidget(const SizedBox());
  });
}
