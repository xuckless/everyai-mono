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

  test('the selection walks the cards in order, stops at the ends, and starts at an end', () {
    const order = ['n1', 'r1', 'r2', 'd1'];
    expect(stepSelection(order, const NoSelection(), 1), 'n1');
    expect(stepSelection(order, const NoSelection(), -1), 'd1');
    expect(stepSelection(order, const SelectedCard('r1'), 1), 'r2');
    expect(stepSelection(order, const SelectedCard('r1'), -1), 'n1');
    expect(stepSelection(order, const SelectedCard('d1'), 1), 'd1');
    expect(stepSelection(order, const SelectedCard('n1'), -1), 'n1');
    // A selected card that's gone starts over.
    expect(stepSelection(order, const SelectedCard('gone'), 1), 'n1');
    expect(stepSelection(const [], const NoSelection(), 1), isNull);
  });

  test('n goes through the cards that need you, wrapping around', () {
    const needs = ['a', 'b'];
    expect(nextNeedingYou(needs, const NoSelection()), 'a');
    expect(nextNeedingYou(needs, const SelectedCard('a')), 'b');
    expect(nextNeedingYou(needs, const SelectedCard('b')), 'a');
    expect(nextNeedingYou(needs, const SelectedCard('elsewhere')), 'a');
    expect(nextNeedingYou(const [], const SelectedCard('a')), isNull);
  });

  test('a selected card that leaves the Board hands the selection to its neighbour', () {
    expect(keepSelection(const SelectedCard('b'), ['a', 'b', 'c'], ['a', 'c']), const SelectedCard('c'));
    expect(keepSelection(const SelectedCard('c'), ['a', 'b', 'c'], ['a', 'b']), const SelectedCard('b'));
    expect(keepSelection(const SelectedCard('a'), ['a'], const []), const NoSelection());
    expect(keepSelection(const SelectedCard('a'), ['a', 'b'], ['b', 'a']), const SelectedCard('a'));
    expect(keepSelection(const NoSelection(), ['a'], const []), const NoSelection());
  });

  test('the filter matches every word in the title, project, harness or branch', () {
    bool m(String q) =>
        matchesBoardFilter(q, title: 'Fix the login', project: 'Alpha', harness: 'Claude Code', branch: 'feat/auth');
    expect(m(''), isTrue);
    expect(m('login'), isTrue);
    expect(m('alpha claude'), isTrue);
    expect(m('AUTH'), isTrue);
    expect(m('login codex'), isFalse);
  });

  test('a sweep covers the Done cards between where it started and where it is, either way', () {
    const done = ['d1', 'd2', 'd3', 'd4'];
    expect(sweptCards(done, 'd2', 'd4'), ['d2', 'd3', 'd4']);
    expect(sweptCards(done, 'd3', 'd1'), ['d1', 'd2', 'd3']);
    // Ending where it began was a click, not a sweep.
    expect(sweptCards(done, 'd2', 'd2'), isEmpty);
    expect(sweptCards(done, 'd2', 'gone'), ['d2']);
    expect(sweptCards(done, 'gone', 'd2'), isEmpty);
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
