// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:io';

import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/live/live_browsers.dart';
import 'package:every_ai/features/code/live/live_session.dart';
import 'package:every_ai/features/code/ui/panes/take_control_reminder.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

// The user took control of a live source in the Preview and forgot: the agent's waiting step shows a reminder in
// the chat, and Allow gives control back.
void main() {
  test('the phases: take, an agent action waits, give back; a wait that runs out goes back to the user', () async {
    final c = LiveControl(hold: const Duration(milliseconds: 50));
    expect(c.phase, LiveControlPhase.agentDriving);
    expect(await c.agentTurn(), isTrue);
    c.take();
    expect(c.phase, LiveControlPhase.userDriving);
    final turn = c.agentTurn();
    expect(c.phase, LiveControlPhase.agentWaiting);
    expect(LiveControl.asking.value, contains(c));
    expect(await turn, isFalse);
    expect(c.phase, LiveControlPhase.userDriving);
    expect(LiveControl.asking.value, isNot(contains(c)));
    final again = c.agentTurn();
    c.giveBack();
    expect(await again, isTrue);
    expect(c.phase, LiveControlPhase.agentDriving);
    expect(c.takeGiveBack(), isTrue);
    expect(LiveControl.asking.value, isEmpty);
  });

  testWidgets('the reminder shows while the session\'s browser waits on the user; Allow gives it back', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('take-control');
    final b = LiveBrowsers.forSession('s1', profileDir: tmp.path);
    await tester.pumpWidget(
      m.MaterialApp(
        home: m.Material(
          child: EveryThemeScope(
            theme: EveryTheme.resolve(DesignLanguage.material, Brightness.dark),
            child: const TakeControlReminder(sessionId: 's1'),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('take-control-reminder')), findsNothing);
    b.control.take();
    await tester.pump();
    // Taking control alone isn't a reminder: only an agent step waiting for it.
    expect(find.byKey(const ValueKey('take-control-reminder')), findsNothing);
    var allowed = false;
    unawaited(b.control.agentTurn().then((v) => allowed = v));
    await tester.pump();
    expect(find.textContaining('Agent would like to take control of the browser', findRichText: true), findsOneWidget);
    expect(find.byKey(const ValueKey('take-control-reminder')), findsOneWidget);
    // Another session's chat doesn't show it.
    expect(waitingControls('s2', LiveControl.asking.value), isEmpty);
    await tester.tap(find.byKey(const ValueKey('take-control-reminder.allow')));
    await tester.pump();
    expect(allowed, isTrue);
    expect(find.byKey(const ValueKey('take-control-reminder')), findsNothing);
    LiveControl.asking.value = const [];
    tmp.deleteSync(recursive: true);
  });
}
