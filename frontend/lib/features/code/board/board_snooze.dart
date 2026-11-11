import 'dart:convert';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/preferences.dart';
import '../domain/transcript.dart';
import '../drivers/usage_limit.dart';

/// A session that stopped on its plan's usage limit, as the Board shows it:
///
/// ```text
///   notLimited ──the lead stops on a usage limit──► limited ──Snooze──► snoozed
///       ▲                                              │                   │
///       │                                              └──the reset passes─┴──► readyToResume
///       └──────────────────── Resume (the lead runs again) ─────────────────────────┘
/// ```
///
/// Only [boardLimitState] decides it, from the limit the transcript ends on, when it resets, and whether the user
/// snoozed the card. Resume is offered, never run by itself (owner, 2026-11-11).
sealed class BoardLimitState {
  const BoardLimitState();
}

final class NotLimited extends BoardLimitState {
  const NotLimited();
}

/// Stopped on a limit that hasn't reset; [resetsAt] when the harness said (Snooze needs it).
final class Limited extends BoardLimitState {
  const Limited(this.resetsAt);
  final DateTime? resetsAt;
}

/// Folded away until [until], when the limit resets.
final class Snoozed extends BoardLimitState {
  const Snoozed(this.until);
  final DateTime until;
}

/// The limit has reset: Resume carries on.
final class ReadyToResume extends BoardLimitState {
  const ReadyToResume();
}

/// [limit] is what the transcript ends on ([stoppedOnLimit]); [snoozedUntil] the card's snooze, if any.
BoardLimitState boardLimitState({UsageLimit? limit, DateTime? snoozedUntil, required DateTime now}) {
  if (limit == null) return const NotLimited();
  final reset = limit.resetsAt;
  if (reset != null && !now.isBefore(reset)) return const ReadyToResume();
  if (snoozedUntil != null && now.isBefore(snoozedUntil)) return Snoozed(snoozedUntil);
  return Limited(reset);
}

/// The usage limit a session stopped on: the last thing its transcript shows, with nothing running since.
UsageLimit? stoppedOnLimit(Transcript t) {
  if (t.running || t.pending.isNotEmpty) return null;
  return switch (t.items.lastOrNull) {
    NoticeItem(:final limit?) => limit,
    _ => null,
  };
}

/// "Resets in 1h 12m", "Resets in 4m", "Resets in under a minute"; [prefix] for other uses ("Back in").
String resetsInText(Duration left, {String prefix = 'Resets in'}) {
  if (left.inMinutes < 1) return '$prefix under a minute';
  final h = left.inHours;
  final m = left.inMinutes % 60;
  if (h == 0) return '$prefix ${m}m';
  if (h >= 24) return '$prefix ${left.inDays}d ${h % 24}h';
  return m == 0 ? '$prefix ${h}h' : '$prefix ${h}h ${m}m';
}

/// Cards the user snoozed until their limit resets (epoch ms by session id); Preferences `code.board.snoozed`.
final boardSnoozedProvider = NotifierProvider<BoardSnoozed, Map<String, int>>(BoardSnoozed.new);

final class BoardSnoozed extends Notifier<Map<String, int>> {
  static const key = 'code.board.snoozed';

  @override
  Map<String, int> build() {
    try {
      return {
        for (final e in (jsonDecode(ref.read(preferencesProvider)[key] ?? '{}') as Map<String, Object?>).entries)
          e.key: (e.value as num).toInt(),
      };
    } on Object {
      return const {};
    }
  }

  void _set(Map<String, int> next) {
    if (mapEquals(next, state)) return;
    state = next;
    ref.read(preferencesProvider)[key] = jsonEncode(next);
  }

  /// Folds [id] away until [until].
  void snooze(String id, DateTime until) => _set({...state, id: until.millisecondsSinceEpoch});

  /// Brings [id] back now.
  void wake(String id) => _set({...state}..remove(id));

  /// Keeps only the snoozes of [ids] (sessions still stopped on a limit).
  void keepOnly(Set<String> ids) => _set({
    for (final e in state.entries)
      if (ids.contains(e.key)) e.key: e.value,
  });

  DateTime? until(String id) => switch (state[id]) {
    final ms? => DateTime.fromMillisecondsSinceEpoch(ms),
    null => null,
  };
}
