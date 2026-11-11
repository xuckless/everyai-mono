import 'package:flutter/services.dart';

import '../harness/events.dart' show ActionCall;

/// Which card the keyboard is on, if any:
///
/// ```text
///   none ──j/k, arrows, n, a click──► on(id) ──j/k, n──► on(other id)
///    ▲                                  │
///    └──── Esc (with no inspector) ─────┘   the card leaving the Board ──► the nearest card, or none
/// ```
sealed class BoardSelection {
  const BoardSelection();
}

final class NoSelection extends BoardSelection {
  const NoSelection();
}

final class SelectedCard extends BoardSelection {
  const SelectedCard(this.id);
  final String id;

  @override
  bool operator ==(Object other) => other is SelectedCard && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// The side inspector:
///
/// ```text
///   closed ──a click on a card, Enter──► open(id) ──another card──► open(other id)
///     ▲                                     │
///     └──── Esc, ×, its session gone ───────┘
/// ```
sealed class BoardInspector {
  const BoardInspector();
}

final class InspectorClosed extends BoardInspector {
  const InspectorClosed();
}

final class InspectorOpen extends BoardInspector {
  const InspectorOpen(this.id);
  final String id;

  @override
  bool operator ==(Object other) => other is InspectorOpen && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// A press-and-drag across Done cards that clears them when let go:
///
/// ```text
///   idle ──press on a Done card──► sweeping(anchor, over) ──drag over another──► sweeping(anchor, over')
///    ▲                                  │
///    └──── let go: clears anchor..over ─┘   (cancelled: clears nothing)
/// ```
sealed class DoneSweep {
  const DoneSweep();
}

final class SweepIdle extends DoneSweep {
  const SweepIdle();
}

final class Sweeping extends DoneSweep {
  const Sweeping(this.anchor, this.over);
  final String anchor;
  final String over;
}

/// The last clear the user can take back, while its bar shows:
///
/// ```text
///   nothing ──cards cleared──► undoable(ids, gen) ──Undo, ⌘Z──► nothing (ids back)
///      ▲                              │
///      └──── 6 s pass (same gen), another clear replaces it ───┘
/// ```
sealed class ClearUndo {
  const ClearUndo();
}

final class NothingToUndo extends ClearUndo {
  const NothingToUndo();
}

final class Undoable extends ClearUndo {
  const Undoable(this.ids, this.generation);
  final List<String> ids;

  /// Which clear this is: the timer of an older one doesn't hide a newer bar.
  final int generation;
}

/// "Approve all" across the Board, one run at a time:
///
/// ```text
///   idle ──Approve all──► confirming (only when risky calls are among them) ──yes──► approving ──► idle
///     ▲                        │ no                                                    (a toast for failures)
///     └────────────────────────┘
/// ```
enum BulkApprove { idle, confirming, approving }

/// What a key does on the Board.
enum BoardKey {
  next,
  previous,
  open,
  openFull,
  approve,
  deny,
  approveAll,
  clear,
  filter,
  escape,
  help,
  nextNeedingYou,
  undo,
}

/// The Board's key map: j/k and the arrows move, Enter opens the inspector (⌘/Ctrl+Enter the full session), a/d
/// approve or deny, A approves everything waiting, x clears a Done card, / filters, n jumps to the next card that
/// needs you, ? shows the keys, Esc steps back, ⌘/Ctrl+Z undoes a clear. Null for any other key.
BoardKey? boardKeyOf(LogicalKeyboardKey key, {bool shift = false, bool meta = false}) {
  if (meta) {
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) return BoardKey.openFull;
    if (key == LogicalKeyboardKey.keyZ && !shift) return BoardKey.undo;
    return null;
  }
  if (key == LogicalKeyboardKey.keyJ || key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.arrowRight) {
    return BoardKey.next;
  }
  if (key == LogicalKeyboardKey.keyK || key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowLeft) {
    return BoardKey.previous;
  }
  if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) return BoardKey.open;
  if (key == LogicalKeyboardKey.keyA) return shift ? BoardKey.approveAll : BoardKey.approve;
  if (key == LogicalKeyboardKey.keyD && !shift) return BoardKey.deny;
  if (key == LogicalKeyboardKey.keyX && !shift) return BoardKey.clear;
  if (key == LogicalKeyboardKey.keyN && !shift) return BoardKey.nextNeedingYou;
  if (key == LogicalKeyboardKey.slash) return shift ? BoardKey.help : BoardKey.filter;
  if (key == LogicalKeyboardKey.question) return BoardKey.help;
  if (key == LogicalKeyboardKey.escape) return BoardKey.escape;
  return null;
}

/// The keys, for the shortcuts overlay.
const boardKeyHelp = [
  ('j  k', 'Next, previous card'),
  ('n', 'Next card that needs you'),
  ('Enter', 'Open in the inspector'),
  ('⌘ Enter', 'Open the full session'),
  ('a  d', 'Approve, deny'),
  ('A', 'Approve everything waiting'),
  ('x', 'Clear a Done card'),
  ('⌘ Z', 'Undo the last clear'),
  ('/', 'Filter'),
  ('Esc', 'Close, then deselect'),
];

/// The card [delta] steps from [current] in [order] (column by column, top to bottom), stopping at the ends. With
/// nothing selected, the first card going forward and the last going back. Null when there are no cards.
String? stepSelection(List<String> order, BoardSelection current, int delta) {
  if (order.isEmpty) return null;
  final at = switch (current) {
    SelectedCard(:final id) => order.indexOf(id),
    NoSelection() => -1,
  };
  if (at < 0) return delta >= 0 ? order.first : order.last;
  return order[(at + delta).clamp(0, order.length - 1)];
}

/// The next card in [needsYou] (top to bottom) after [current], wrapping around; the first when [current] isn't one
/// of them. Null when nothing needs the user.
String? nextNeedingYou(List<String> needsYou, BoardSelection current) {
  if (needsYou.isEmpty) return null;
  final at = current is SelectedCard ? needsYou.indexOf(current.id) : -1;
  return needsYou[(at + 1) % needsYou.length];
}

/// Where the selection goes when its card left the shown cards ([before] → [after]): the card that now sits where it
/// was, else the one before it; none when the Board is empty.
BoardSelection keepSelection(BoardSelection current, List<String> before, List<String> after) {
  if (current is! SelectedCard || after.contains(current.id)) return current;
  if (after.isEmpty) return const NoSelection();
  final was = before.indexOf(current.id);
  if (was < 0) return const NoSelection();
  return SelectedCard(after[was.clamp(0, after.length - 1)]);
}

/// Whether a card matches the filter text: every word in [query] is in its title, project, harness or branch (case
/// ignored). An empty query matches everything.
bool matchesBoardFilter(
  String query, {
  required String title,
  String project = '',
  String harness = '',
  String branch = '',
}) {
  final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  final hay = '$title $project $harness $branch'.toLowerCase();
  return words.every(hay.contains);
}

/// The Done cards a sweep from [anchor] to [over] covers, in [doneOrder] (top to bottom), both ends included.
List<String> sweptCards(List<String> doneOrder, String anchor, String over) {
  final a = doneOrder.indexOf(anchor);
  final b = doneOrder.indexOf(over);
  if (a < 0) return const [];
  if (b < 0) return [anchor];
  final (lo, hi) = a <= b ? (a, b) : (b, a);
  return doneOrder.sublist(lo, hi + 1);
}

/// One session's approvals waiting, with the calls the risk check flags ([flags], call id → why).
typedef WaitingApprovals = ({String sessionId, String title, List<ActionCall> pending, Map<String, String> flags});

/// One flagged call, for the confirm dialog.
typedef RiskyCall = ({String sessionId, String title, String callId, String why});

/// Everything waiting across the Board, split into what Approve all may approve without asking and the flagged calls
/// it confirms first (once, listing them). Sessions with nothing pending are left out.
({int calls, int sessions, List<RiskyCall> risky}) bulkApprovePlan(Iterable<WaitingApprovals> waiting) {
  var calls = 0;
  var sessions = 0;
  final risky = <RiskyCall>[];
  for (final w in waiting) {
    if (w.pending.isEmpty) continue;
    sessions++;
    calls += w.pending.length;
    for (final c in w.pending) {
      if (w.flags[c.id] case final why?) risky.add((sessionId: w.sessionId, title: w.title, callId: c.id, why: why));
    }
  }
  return (calls: calls, sessions: sessions, risky: risky);
}
