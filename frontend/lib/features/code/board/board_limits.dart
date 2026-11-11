import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../../core/format/money.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../usage/usage_totals.dart';
import '../harness/events.dart' show PlanLimits, PlanWindow;
import '../settings/code_settings.dart' show budgetFill;
import '../ui/console/session_info_view.dart' show planWindowName;
import '../ui/transcript/lead_offer_card.dart' show resetText;
import '../ui/transcript/plan_report_view.dart' show PlanLimitBar;

/// One bar of the Board's limits strip: a plan window pooled across the sessions on one harness, or the spending cap
/// closest to full. [sessions] are the ones it covers, in Board order.
@immutable
final class BoardLimit {
  const BoardLimit({
    required this.key,
    required this.label,
    required this.used,
    required this.sessions,
    this.scope,
    this.resetsAt,
  });

  /// `harness|window`, or `cap`.
  final String key;
  final String label;
  final String? scope;

  /// 0 to 1.
  final double used;
  final DateTime? resetsAt;
  final List<String> sessions;

  int get percent => (used * 100).round().clamp(0, 100);

  @override
  bool operator ==(Object other) =>
      other is BoardLimit &&
      other.key == key &&
      other.label == label &&
      other.scope == scope &&
      other.used == used &&
      other.resetsAt == resetsAt &&
      listEquals(other.sessions, sessions);

  @override
  int get hashCode => Object.hash(key, label, scope, used, resetsAt, Object.hashAll(sessions));
}

/// A session's latest plan report, for [poolPlanLimits].
typedef SessionPlan = ({String sessionId, String harness, String harnessLabel, PlanLimits plan});

/// The plan windows the Board's sessions report, one bar per harness and window (sessions on one harness share one
/// plan): of their readings the one for the latest window (a later reset), then the fullest. A window whose reset has
/// passed says nothing about now and is left out. Fullest first.
List<BoardLimit> poolPlanLimits(List<SessionPlan> plans, {required DateTime now}) {
  final best = <String, ({String harnessLabel, PlanWindow window})>{};
  final users = <String, List<String>>{};
  for (final p in plans) {
    for (final w in p.plan.windows) {
      if (w.resetsAt case final at? when !at.isAfter(now)) continue;
      final key = '${p.harness}|${w.name}';
      (users[key] ??= []).add(p.sessionId);
      final had = best[key]?.window;
      if (had == null || _newer(w, had)) best[key] = (harnessLabel: p.harnessLabel, window: w);
    }
  }
  return [
    for (final MapEntry(:key, :value) in best.entries)
      BoardLimit(
        key: key,
        label: value.harnessLabel,
        scope: planWindowName(value.window),
        used: value.window.used.clamp(0, 1).toDouble(),
        resetsAt: value.window.resetsAt,
        sessions: users[key]!,
      ),
  ]..sort((a, b) => b.used.compareTo(a.used));
}

/// Whether reading [a] says more about now than [b]: a later window, else more of the same one used.
bool _newer(PlanWindow a, PlanWindow b) {
  final at = a.resetsAt;
  final bt = b.resetsAt;
  if (at != null && bt != null && at.difference(bt).abs() > const Duration(minutes: 10)) return at.isAfter(bt);
  return a.used > b.used;
}

/// A session's spend against its cap, for [busiestCap].
typedef SessionCap = ({String sessionId, String title, int chargedMicros, double? budgetUsd});

/// The spending cap closest to full among the Board's sessions, as one bar ("Session cap · <title>"): caps are per
/// session, so the one about to stop a session is the one worth showing. Null when no shown session has a cap.
BoardLimit? busiestCap(List<SessionCap> caps) {
  ({SessionCap cap, double fill})? top;
  for (final c in caps) {
    final fill = budgetFill(c.chargedMicros, c.budgetUsd);
    if (fill == null) continue;
    if (top == null || fill > top.fill) top = (cap: c, fill: fill);
  }
  if (top == null) return null;
  return BoardLimit(
    key: 'cap',
    label: 'Session cap',
    scope: '${top.cap.title} · ${formatMicros((top.cap.budgetUsd! * 1e6).round())}',
    used: top.fill.clamp(0, 1).toDouble(),
    sessions: [top.cap.sessionId],
  );
}

/// A card's cost, in mono: what it spent ("$0.42"), else its tokens on the user's plan ("42.4M on your plan"), else
/// its tokens; '' before its first model call.
String boardCostLine(UsageTotals t) {
  if (t.isEmpty) return '';
  if (t.spentMicros > 0) return formatMicros(t.spentMicros);
  final tokens = formatTokens(t.totalTokens);
  return t.onPlan ? '$tokens on your plan' : '$tokens tokens';
}

/// The Board header's strip: one compact bar per [limits] entry; a click lists the sessions it covers, and picking one
/// opens it ([onSession]). Nothing when no limit is known.
class BoardLimitsStrip extends StatelessWidget {
  const BoardLimitsStrip({
    super.key,
    required this.limits,
    required this.titles,
    required this.onSession,
    this.now = DateTime.now,
  });

  final List<BoardLimit> limits;

  /// Session titles by id, for the menu.
  final Map<String, String> titles;
  final ValueChanged<String> onSession;
  final DateTime Function() now;

  @override
  Widget build(BuildContext context) {
    if (limits.isEmpty) return const SizedBox.shrink(key: ValueKey('board.limits.none'));
    final at = now();
    return Wrap(
      key: const ValueKey('board.limits'),
      spacing: 16,
      runSpacing: 10,
      children: [
        for (final l in limits)
          SizedBox(
            width: 210,
            child: AdaptiveMenuButton(
              key: ValueKey('board.limit.${l.key}'),
              tooltip: l.sessions.length == 1 ? 'Used by 1 session' : 'Used by ${l.sessions.length} sessions',
              width: 260,
              actions: [
                for (final id in l.sessions)
                  MenuAction(label: titles[id] ?? 'Session', onSelected: () => onSession(id)),
              ],
              child: PlanLimitBar(
                label: l.label,
                scope: l.scope,
                percent: l.percent,
                resets: l.resetsAt == null ? null : 'resets ${resetText(l.resetsAt!, at)}',
                compact: true,
              ),
            ),
          ),
      ],
    );
  }
}

/// The strip's text colour for a cost line on a card (quiet, mono).
TextStyle boardCostStyle(EveryTheme theme) => theme.type.caption.mono.tint(theme.textSubtle);
