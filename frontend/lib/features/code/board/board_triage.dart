import 'package:flutter/services.dart';

import '../../../core/platform/platform_kind.dart' show Host;

import '../harness/events.dart' show ActionCall;
import 'board_providers.dart' show SeenState;

/// Which card the keyboard is on, if any. While the inspector is open the selection is the inspected card (j/k and
/// n move both together), so a/d/x always act on the session the inspector shows:
///
/// ```text
///   none ──j/k, arrows, n, a click──► on(id) ──j/k, n──► on(other id)
///    ▲                                  │
///    └──── Esc (with no inspector) ─────┘   the card leaving the Board ──► the nearest card, or none
///                                            (not while the inspector shows it: it stays on that session)
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

/// Who gets the keys when the inspector opens or moves: the Board (opened from the keyboard; j/k/n carry it along)
/// or the inspector's composer (a click: a reply typed at once is text, not Board keys).
enum InspectorKeys { board, composer }

/// What the inspector shows of a session: its recent transcript read-only ([preview]: nothing is attached, no
/// controller is made for a card merely looked at), or the session itself ([live]: its controller, approvals and
/// composer). A session with an open controller is always shown live; a preview goes live only when the user acts.
enum InspectorView { preview, live }

/// What the inspector's body shows:
///
/// ```text
///   loading ──the transcript arrives──► transcript
///      └──nothing came back (preview)──► empty
/// ```
/// A live session is loading while it connects with nothing to show yet (a closed session reopening replays its
/// history); a failure ends the loading so the error shows. A preview is loading until its read answers.
enum InspectorBody { loading, empty, transcript }

/// The live view's body: its transcript, or loading while the session connects and has shown nothing.
InspectorBody liveInspectorBody({required bool connected, required bool failed, required bool hasItems}) =>
    !connected && !failed && !hasItems ? InspectorBody.loading : InspectorBody.transcript;

/// The preview's body, from its read ([loading] until it answers; [found] when it found a transcript).
InspectorBody previewInspectorBody({required bool loading, required bool found}) => loading
    ? InspectorBody.loading
    : found
    ? InspectorBody.transcript
    : InspectorBody.empty;

/// The side inspector. Each open or move bumps [generation], so a repeated click on the same card is a new request
/// for [keys]:
///
/// ```text
///   closed ──a click on a card, Enter──► open(id, keys, view, gen)
///     ▲                                     │ another card, j/k/n ──► open(other id, board, preview, gen+1)
///     │                                     │ a click on the card ──► open(id, composer, gen+1)
///     │                                     │ Reply (preview) ──► open(id, composer, live, gen+1)
///     └──── Esc, ×, its session gone ───────┘
/// ```
sealed class BoardInspector {
  const BoardInspector();
}

final class InspectorClosed extends BoardInspector {
  const InspectorClosed();
}

final class InspectorOpen extends BoardInspector {
  const InspectorOpen(
    this.id, {
    this.keys = InspectorKeys.board,
    this.view = InspectorView.preview,
    this.generation = 0,
  });
  final String id;
  final InspectorKeys keys;
  final InspectorView view;
  final int generation;

  @override
  bool operator ==(Object other) =>
      other is InspectorOpen &&
      other.id == id &&
      other.keys == keys &&
      other.view == view &&
      other.generation == generation;

  @override
  int get hashCode => Object.hash(id, keys, view, generation);
}

/// Where the inspector sits, as last laid out: beside the columns, or covering them (a narrow window; the hidden
/// cards then take no keys).
enum InspectorLayout { beside, covering }

/// The inspector's width while its edge is dragged (written when the drag ends):
///
/// ```text
///   idle ──drag the edge──► dragging(width) ──let go, cancel, the window narrows (no edge) ──► idle
/// ```
sealed class InspectorDrag {
  const InspectorDrag();
}

final class DragIdle extends InspectorDrag {
  const DragIdle();
}

final class DragActive extends InspectorDrag {
  const DragActive(this.width);
  final double width;
}

/// A press-and-drag across Done cards (mouse) that clears them when let go. A press alone is still a click: the sweep
/// starts only once the pointer reaches a second Done card, and it reads raw pointer events, so it never takes a
/// click from the card's own buttons:
///
/// ```text
///   idle ──press on a Done card──► pressed(anchor) ──pointer over another Done card──► sweeping(anchor, over)
///    ▲                                  │ let go (a click)                                   │ over another ──► sweeping(anchor, over')
///    ├──────────────────────────────────┘                                                    │
///    └──── let go: clears anchor..over (nothing when it ends on its anchor); Esc, cancel: nothing ┘
/// ```
sealed class DoneSweep {
  const DoneSweep();
}

final class SweepIdle extends DoneSweep {
  const SweepIdle();
}

final class SweepPressed extends DoneSweep {
  const SweepPressed(this.anchor);
  final String anchor;
}

final class Sweeping extends DoneSweep {
  const Sweeping(this.anchor, this.over);
  final String anchor;
  final String over;
}

/// The last clear the user can take back, while its bar shows. It keeps each card's seen state ([marks]: when it
/// finished, whether it was seen), so Undo puts them back as they were (not as fresh, unseen finishes):
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
  const Undoable(this.ids, this.generation, {this.marks = const {}});
  final List<String> ids;

  /// Each cleared card's marks, as the Board had them.
  final Map<String, SeenState> marks;

  /// Which clear this is: the timer of an older one doesn't hide a newer bar.
  final int generation;
}

/// "Approve all" across the Board, one run at a time. It always confirms when it spans more than one session or
/// includes flagged calls:
///
/// ```text
///   idle ──Approve all──► confirming (several sessions, or risky calls among them) ──yes──► approving ──► idle
///     ▲                        │ no                                                            (a toast for failures)
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
/// needs you, ? shows the keys, Esc steps back, ⌘/Ctrl+Z undoes a clear. Null for any other key, and for any key
/// pressed with Alt/Option ([alt]).
///
/// `/` and `?` go by the [character] typed when there is one, since keyboard layouts put them on different keys
/// (Shift+7 is `/` on a German keyboard).
BoardKey? boardKeyOf(
  LogicalKeyboardKey key, {
  bool shift = false,
  bool meta = false,
  bool alt = false,
  String? character,
}) {
  // Option+A types å: a key with Alt/Option held is text, not a Board key.
  if (alt) return null;
  if (!meta) {
    if (character == '?') return BoardKey.help;
    if (character == '/') return BoardKey.filter;
  }
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

/// The keys, for the shortcuts overlay; [apple] writes the modifier as ⌘, else Ctrl.
List<(String, String)> boardKeyHelp({required bool apple}) {
  final mod = apple ? '⌘' : 'Ctrl+';
  return [
    ('j  k', 'Next, previous card'),
    ('n', 'Next card that needs you'),
    (Host.enterKeys(), 'Open in the inspector'),
    (Host.enterKeys(command: true), 'Open the full session'),
    ('a  d', 'Approve, deny'),
    ('A', 'Approve everything waiting'),
    ('x', 'Clear a Done card'),
    ('${mod}Z', 'Undo the last clear'),
    ('/', 'Filter'),
    ('Esc', 'Close, then deselect'),
  ];
}

/// Whether a held key repeats [action]: only moving does; a held x, a or d acts once.
bool boardKeyRepeats(BoardKey action) => action == BoardKey.next || action == BoardKey.previous;

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

/// The Done cards a sweep from [anchor] to [over] covers, in [doneOrder] (top to bottom), both ends included. None
/// when it ends where it began (that was a click, not a sweep).
List<String> sweptCards(List<String> doneOrder, String anchor, String over) {
  if (anchor == over) return const [];
  final a = doneOrder.indexOf(anchor);
  final b = doneOrder.indexOf(over);
  if (a < 0) return const [];
  if (b < 0) return [anchor];
  final (lo, hi) = a <= b ? (a, b) : (b, a);
  return doneOrder.sublist(lo, hi + 1);
}

/// One session's approvals waiting, with the calls the risk check flags ([flags], call id → why).
typedef WaitingApprovals = ({String sessionId, String title, List<ActionCall> pending, Map<String, String> flags});

/// One flagged call, for the confirm dialog: what it runs ([what], the approval's own title) and why it is flagged.
typedef RiskyCall = ({String sessionId, String title, String callId, String what, String why});

/// Everything waiting across the Board, split into what Approve all may approve without asking and the flagged calls
/// it confirms first (once, listing them). Sessions with nothing pending are left out.
/// [waiting]'s `pending` must already leave out calls decided one by one (see [undecidedCalls]). [what] names a call
/// for the list.
({int calls, int sessions, List<RiskyCall> risky}) bulkApprovePlan(
  Iterable<WaitingApprovals> waiting, {
  String Function(ActionCall call)? what,
}) {
  var calls = 0;
  var sessions = 0;
  final risky = <RiskyCall>[];
  for (final w in waiting) {
    if (w.pending.isEmpty) continue;
    sessions++;
    calls += w.pending.length;
    for (final c in w.pending) {
      if (w.flags[c.id] case final why?) {
        risky.add((sessionId: w.sessionId, title: w.title, callId: c.id, what: what?.call(c) ?? c.toolName, why: why));
      }
    }
  }
  return (calls: calls, sessions: sessions, risky: risky);
}

/// The calls of [pending] not yet decided one by one ([decided]: call id → allowed): a call the user allowed or denied
/// in the per-call menu keeps that answer, whatever Approve or Deny on the whole card does.
List<ActionCall> undecidedCalls(List<ActionCall> pending, Map<String, bool> decided) => [
  for (final c in pending)
    if (!decided.containsKey(c.id)) c,
];

/// Which of [planned] (the call ids a confirm showed) a bulk run may still send for one session, given what waits now
/// ([nowUndecided]). A harness that answers whole batches only ([perCall] false) is skipped unless the batch is the
/// very one confirmed: its answer would reach calls nobody saw. Null: skip the session.
List<String>? bulkTargets({required List<String> planned, required List<String> nowUndecided, required bool perCall}) {
  if (!perCall) {
    final same = planned.length == nowUndecided.length && planned.toSet().containsAll(nowUndecided);
    return same ? planned : null;
  }
  return [
    for (final id in planned)
      if (nowUndecided.contains(id)) id,
  ];
}

/// What a call runs, in one short line for the Approve all list: the command itself, the file it writes, else the
/// tool's name.
String bulkCallLine(ActionCall call) {
  String cut(String t) {
    final line = t.trim().split('\n').first;
    return line.length <= 80 ? line : '${line.substring(0, 79)}…';
  }

  final command = call.str('command');
  return switch (call.actionKind) {
    'TerminalAction' when command.trim().isNotEmpty => cut(command),
    'FileEditorAction' || 'ApplyPatchAction' when call.str('path').isNotEmpty =>
      '${call.actionKind == 'ApplyPatchAction' ? 'Patch' : 'Edit'} ${call.str('path')}',
    _ => call.nativeName.isEmpty ? call.toolName : call.nativeName,
  };
}

/// Whether a segmented control of [count] options fits in [maxWidth]: each option is as wide as the widest label
/// ([widestLabel]) plus its padding (12 a side), inside the control's own 4 a side ([KitSegmented]'s sizes).
bool segmentsFit({required int count, required double widestLabel, required double maxWidth}) =>
    count * (widestLabel + 24) + 8 <= maxWidth;
