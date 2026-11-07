// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/domain/session_work.dart';
import 'package:every_ai/features/code/ui/stop_all_button.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

// Stop all: one row behind a small chevron, naming what it stops.
void main() {
  test('what Stop all stops, in words', () {
    expect(hasSideWork((forks: 0, workflows: const [])), isFalse);
    expect(hasSideWork((forks: 1, workflows: const [])), isTrue);
    expect(
      stopAllScope((forks: 2, workflows: const ['Security review']), leadBusy: true),
      'the lead, 2 forks and Security review',
    );
    expect(stopAllScope((forks: 1, workflows: const []), leadBusy: false), '1 fork');
    expect(stopAllScope((forks: 0, workflows: const ['Ultra']), leadBusy: true), 'the lead and Ultra');
  });

  testWidgets('the chevron opens the Stop all row; picking it stops once', (tester) async {
    var stopped = 0;
    await tester.pumpWidget(
      m.MaterialApp(
        home: m.Material(
          child: EveryThemeScope(
            theme: EveryTheme.resolve(DesignLanguage.material, Brightness.dark),
            child: Center(
              child: StopAllButton(
                work: (forks: 2, workflows: const ['Security review']),
                leadBusy: true,
                onStopAll: () => stopped++,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('stop-all')));
    await tester.pumpAndSettle();
    final row = find.text('Stop all · the lead, 2 forks and Security review');
    expect(row, findsOneWidget);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(stopped, 1);
    expect(row, findsNothing);
  });
}
