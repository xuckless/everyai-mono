// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:every_ai/features/code/live/live_session.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
