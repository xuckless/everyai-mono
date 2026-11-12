import 'package:every_ai/features/code/board/board_triage.dart';
import 'package:every_ai/features/code/drivers/driver_events.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the Board keys: j/k and arrows move, a/d/A decide, x clears, n jumps, / filters, ? helps', () {
    expect(boardKeyOf(LogicalKeyboardKey.keyJ), BoardKey.next);
    expect(boardKeyOf(LogicalKeyboardKey.arrowDown), BoardKey.next);
    expect(boardKeyOf(LogicalKeyboardKey.keyK), BoardKey.previous);
    expect(boardKeyOf(LogicalKeyboardKey.arrowUp), BoardKey.previous);
    expect(boardKeyOf(LogicalKeyboardKey.enter), BoardKey.open);
    expect(boardKeyOf(LogicalKeyboardKey.enter, meta: true), BoardKey.openFull);
    expect(boardKeyOf(LogicalKeyboardKey.keyA), BoardKey.approve);
    expect(boardKeyOf(LogicalKeyboardKey.keyA, shift: true), BoardKey.approveAll);
    expect(boardKeyOf(LogicalKeyboardKey.keyD), BoardKey.deny);
    expect(boardKeyOf(LogicalKeyboardKey.keyX), BoardKey.clear);
    expect(boardKeyOf(LogicalKeyboardKey.keyN), BoardKey.nextNeedingYou);
    expect(boardKeyOf(LogicalKeyboardKey.slash), BoardKey.filter);
    expect(boardKeyOf(LogicalKeyboardKey.slash, shift: true), BoardKey.help);
    expect(boardKeyOf(LogicalKeyboardKey.escape), BoardKey.escape);
    expect(boardKeyOf(LogicalKeyboardKey.keyZ, meta: true), BoardKey.undo);
    // Other keys, and ⌘ with a letter the Board doesn't use, are left alone.
    expect(boardKeyOf(LogicalKeyboardKey.keyQ), isNull);
    expect(boardKeyOf(LogicalKeyboardKey.keyA, meta: true), isNull);
    // `/` and `?` go by the character typed: Shift+7 is `/` on a German keyboard, and that filters.
    expect(boardKeyOf(LogicalKeyboardKey.digit7, shift: true, character: '/'), BoardKey.filter);
    expect(boardKeyOf(LogicalKeyboardKey.slash, shift: true, character: '?'), BoardKey.help);
    // Only moving repeats when a key is held.
    expect(boardKeyRepeats(BoardKey.next), isTrue);
    expect(boardKeyRepeats(BoardKey.previous), isTrue);
    expect([BoardKey.clear, BoardKey.approve, BoardKey.deny, BoardKey.approveAll].any(boardKeyRepeats), isFalse);
    // The keys overlay writes the host's modifier.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(boardKeyHelp(apple: true).map((e) => e.$1), containsAll([Host.enterKeys(command: true), '⌘Z']));
    expect(Host.enterKeys(command: true), startsWith('⌘'));
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(boardKeyHelp(apple: false).map((e) => e.$1), containsAll(['Ctrl+Enter', 'Ctrl+Z']));
    debugDefaultTargetPlatformOverride = null;
    // Option+A types å: Alt held makes it text, not a Board key.
    expect(boardKeyOf(LogicalKeyboardKey.keyA, alt: true), isNull);
    expect(boardKeyOf(LogicalKeyboardKey.keyJ, alt: true), isNull);
  });

  test('Approve all counts every waiting call and lists the flagged ones for one confirm', () {
    final rm = actionEvent(id: 'c1', toolName: 'bash', kind: 'TerminalAction', args: const {'command': 'rm -rf /'});
    final ls = actionEvent(id: 'c2', toolName: 'bash', kind: 'TerminalAction', args: const {'command': 'ls'});
    final plan = bulkApprovePlan([
      (sessionId: 's1', title: 'One', pending: [rm, ls], flags: const {'c1': 'Deletes files'}),
      (sessionId: 's2', title: 'Two', pending: [ls], flags: const {}),
      (sessionId: 's3', title: 'Idle', pending: const [], flags: const {}),
    ], what: (c) => c.str('command'));
    expect(plan.calls, 3);
    expect(plan.sessions, 2);
    expect(plan.risky, [(sessionId: 's1', title: 'One', callId: 'c1', what: 'rm -rf /', why: 'Deletes files')]);
    expect(bulkApprovePlan(const []).calls, 0);
  });

  test('calls decided one by one keep their answer; a bulk run sends only what the confirm counted', () {
    final a = actionEvent(id: 'a', toolName: 'bash', kind: 'TerminalAction', args: const {'command': 'ls'});
    final b = actionEvent(id: 'b', toolName: 'bash', kind: 'TerminalAction', args: const {'command': 'pwd'});
    expect(
      [
        for (final c in undecidedCalls([a, b], const {'a': false})) c.id,
      ],
      ['b'],
    );
    // Per call: what still waits of the planned calls (a new one waits for its own look).
    expect(bulkTargets(planned: ['a', 'b'], nowUndecided: ['b', 'c'], perCall: true), ['b']);
    // Whole batches only: the very batch confirmed, or nothing.
    expect(bulkTargets(planned: ['a', 'b'], nowUndecided: ['b', 'a'], perCall: false), ['a', 'b']);
    expect(bulkTargets(planned: ['a'], nowUndecided: ['a', 'c'], perCall: false), isNull);
  });
}
