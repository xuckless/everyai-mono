// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/foundation.dart';

import '../harness/events.dart' show PlanWindow;

// What a running workflow is measured by while it runs (owner, 2026-11-08), only where the app can read it for real:
//
//   - An EveryAI lead: dollars against the estimate the user approved. Rows at 50% and 80%; at 100% the run pauses
//     and the user decides (Continue raises the ceiling by half; Stop; Adjust). The hard cap stays in WorkflowCaps.
//   - An outside lead that reports plan limits: each window's use against what was left of it at the start. Rows at
//     50%, 80% and 90% of that share; it never pauses (the CLI's own limit handling takes over).
//   - Anything else (no estimate, no limits reported): nothing. Wall time is never a measure.
//
// Each mark is passed once; [GuardMarks] keeps which, and the journal keeps them across a restart. Over the estimate
// isn't kept: a resumed run that is still over pauses again.

/// One mark a run passed.
@immutable
sealed class GuardEvent {
  const GuardEvent(this.id, this.text);

  /// Stable per mark (journalled, so a resume doesn't repeat it).
  final String id;

  /// The card's row.
  final String text;
}

/// A row on the card, no decision needed.
final class GuardMark extends GuardEvent {
  const GuardMark(super.id, super.text);
}

/// Past the estimate's ceiling: the run pauses and the user decides.
final class GuardOver extends GuardEvent {
  const GuardOver(super.id, super.text, {required this.ceilingMicros});
  final int ceilingMicros;
}

String _usd(int micros) => '\$${(micros / 1e6).toStringAsFixed(2)}';

/// The marks of one run.
final class GuardMarks {
  GuardMarks({this.ceilingMicros, Map<String, double> windowsAtStart = const {}, Iterable<String> passed = const []})
    : _start = windowsAtStart,
      _passed = {...passed};

  /// The dollar estimate's top (an EveryAI lead), raised by [raise]; null: no dollar measure.
  int? ceilingMicros;

  /// Each plan window's use when the run started (an outside lead), by name.
  final Map<String, double> _start;
  final Set<String> _passed;

  /// The marks passed so far (for the journal).
  Set<String> get passed => Set.unmodifiable(_passed);

  /// What [spentMicros] passed since the last call.
  List<GuardEvent> spend(int spentMicros) {
    final ceiling = ceilingMicros;
    if (ceiling == null || ceiling <= 0) return const [];
    final out = <GuardEvent>[];
    for (final pct in const [50, 80]) {
      final id = 'spend$pct@$ceiling';
      if (spentMicros * 100 >= ceiling * pct && _passed.add(id)) {
        out.add(GuardMark(id, '$pct% of the estimate used (${_usd(spentMicros)} of ${_usd(ceiling)})'));
      }
    }
    if (spentMicros >= ceiling) {
      out.add(
        GuardOver(
          'over@$ceiling',
          'Past the estimate: ${_usd(spentMicros)} of ${_usd(ceiling)}. Paused until you decide.',
          ceilingMicros: ceiling,
        ),
      );
    }
    return out;
  }

  /// Continue past the estimate: the ceiling goes up by half, and the marks of the new ceiling that [spentMicros]
  /// already passed count as passed (the next row is the next mark ahead, not a 50% after the pause).
  void raise({int spentMicros = 0}) {
    final c = ceilingMicros;
    if (c == null) return;
    final next = ceilingMicros = c + c ~/ 2;
    for (final pct in const [50, 80]) {
      if (spentMicros * 100 >= next * pct) _passed.add('spend$pct@$next');
    }
  }

  /// What the plan [windows] passed since the last call (a window unknown at the start counts from now).
  List<GuardEvent> windows(List<PlanWindow> windows, String Function(PlanWindow w) label) {
    final out = <GuardEvent>[];
    for (final w in windows) {
      final at = _start[w.name] ??= w.used;
      final left = 1 - at;
      if (left <= 0) continue;
      for (final pct in const [50, 80, 90]) {
        final id = 'limit:${w.name}:$pct';
        // A hair of tolerance: 0.4 + 0.6 × 0.5 is 0.7000000000000001 in floating point.
        if (w.used + 1e-9 >= at + left * pct / 100 && _passed.add(id)) {
          out.add(
            GuardMark(id, '${label(w)}: $pct% of what was left at the start used (${(w.used * 100).round()}% now)'),
          );
        }
      }
    }
    return out;
  }
}
