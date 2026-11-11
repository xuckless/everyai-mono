// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';

import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/live/live_session.dart';
import 'package:every_ai/features/code/ui/panes/preview_apps.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

// Live views are watch-only until the bar's Take control; clicking never takes control.
void main() {
  test('only the user\'s phases let input through; a locked try is counted for the bar to pulse', () {
    final c = LiveControl();
    expect(c.mayAct(), isFalse);
    expect(c.takeHints.value, 1);
    c.take();
    expect(c.mayAct(), isTrue);
    expect(c.takeHints.value, 1);
    c.giveBack();
    expect(c.phase.userMayAct, isFalse);
  });

  testWidgets('the bar says who has the view and its button is the only way to switch', (tester) async {
    final c = LiveControl(hold: const Duration(minutes: 1));
    addTearDown(c.dispose);
    await tester.pumpWidget(
      m.MaterialApp(
        home: m.Material(
          child: EveryThemeScope(
            theme: EveryTheme.resolve(DesignLanguage.material, Brightness.dark),
            child: LiveDriverBar(control: c, noun: 'page'),
          ),
        ),
      ),
    );
    expect(find.text('Agent is using this page'), findsOneWidget);
    expect(find.text('Take control'), findsOneWidget);
    await tester.tap(find.text('Take control'));
    await tester.pump();
    expect(c.phase, LiveControlPhase.userDriving);
    expect(find.text('You have control'), findsOneWidget);
    expect(find.text('Give back'), findsOneWidget);
    unawaited(c.agentTurn());
    await tester.pump();
    expect(find.text('Agent is waiting · you have control'), findsOneWidget);
    await tester.tap(find.text('Give back'));
    await tester.pump();
    expect(find.text('Agent is using this page'), findsOneWidget);
    expect(LiveDriverBar.textFor(LiveControlPhase.agentDriving, 'device'), 'Agent is using this device');
  });
}
