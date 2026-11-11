import 'package:every_ai/features/code/board/board_triage.dart';
import 'package:every_ai/features/code/drivers/driver_events.dart';
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
    expect(sweptCards(done, 'd2', 'd2'), ['d2']);
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
    ]);
    expect(plan.calls, 3);
    expect(plan.sessions, 2);
    expect(plan.risky, [(sessionId: 's1', title: 'One', callId: 'c1', why: 'Deletes files')]);
    expect(bulkApprovePlan(const []).calls, 0);
  });
}
