import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/router.dart';
import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/anchored_popover.dart';
import '../../../../core/ui/every_icons.dart';
import '../../../billing/billing_providers.dart' show formatMicros;
import '../domain/ultra_plan.dart';
import '../ultra_ui_providers.dart';

/// The top bar's Ultra slot (see `codeUltraSlotProvider`).
Widget ultraTopBarSlot(BuildContext context, String sessionId) => UltraChip(sessionId: sessionId);

/// "Ultra" in the Code top bar: a popover with the toggle and the run's caps.
/// Locked (with the reason) off the Max plan; hidden in the demo and in child
/// sessions.
class UltraChip extends ConsumerWidget {
  const UltraChip({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ultraSessionEligible(ref, sessionId)) return const SizedBox.shrink();
    final theme = EveryTheme.of(context);
    final toggle = ref.watch(ultraToggleProvider(sessionId));
    final access = ref.watch(ultraAccessProvider);
    final running = ref.watch(sessionUltraRunsProvider(sessionId)).where((e) => e.active).length;
    final locked = access.value == null;
    final on = toggle.armed && !locked;
    final color = on || running > 0 ? theme.accent : theme.textMuted;
    return AnchoredPopover(
      width: 320,
      builder: (context, close) => UltraPanel(sessionId: sessionId, close: close),
      child: Semantics(
        button: true,
        toggled: on,
        label: locked ? 'Ultra (Max plan)' : 'Ultra ${on ? 'on' : 'off'}',
        child: Container(
          key: const ValueKey('ultra.chip'),
          margin: const EdgeInsets.only(left: 4),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: on ? theme.accent.withValues(alpha: 0.12) : null,
            border: Border.all(color: on ? theme.accent.withValues(alpha: 0.6) : theme.border),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AdaptiveIcon(EveryIcon.spark, size: 13, color: color),
              const SizedBox(width: 5),
              Text(
                running > 0 ? 'Ultra · $running' : 'Ultra',
                style: TextStyle(color: color, fontSize: 12.5, fontWeight: on ? FontWeight.w600 : null),
              ),
              if (locked && access.hasValue) ...[
                const SizedBox(width: 4),
                Text('Max', style: TextStyle(color: theme.textMuted, fontSize: 10.5)),
              ],
              const SizedBox(width: 4),
              AdaptiveIcon(EveryIcon.chevronDown, size: 10, color: color),
            ],
          ),
        ),
      ),
    );
  }
}

/// The Ultra popover: the toggle, the caps (within the plan's), and Stop all.
class UltraPanel extends ConsumerWidget {
  const UltraPanel({super.key, required this.sessionId, required this.close});

  final String sessionId;
  final VoidCallback close;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final toggle = ref.watch(ultraToggleProvider(sessionId));
    final controller = ref.read(ultraToggleProvider(sessionId).notifier);
    final access = ref.watch(ultraAccessProvider);
    final running = ref.watch(sessionUltraRunsProvider(sessionId)).where((e) => e.active).length;
    final max = access.value;
    final l = toggle.limits;

    // From the current caps, so quick taps build on each other.
    void set(UltraLimits Function(UltraLimits now) step) =>
        controller.setLimits(step(ref.read(ultraToggleProvider(sessionId)).limits), max: max ?? const UltraLimits());

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PopoverRow(
            key: const ValueKey('ultra.toggle'),
            title: 'Ultra',
            subtitle: switch (access) {
              AsyncValue(isLoading: true, hasValue: false) => 'Checking your plan…',
              AsyncValue(hasError: true, hasValue: false) => "Couldn't check your plan",
              _ when max == null => 'Part of the Max plan',
              _ =>
                toggle.armed
                    ? 'Your next message starts a run: an orchestrator plans, many agents work'
                    : 'Plan a goal and fan it out to many agents at once',
            },
            trailing: AdaptiveSwitch(
              value: toggle.armed && max != null,
              onChanged: max == null ? null : controller.setArmed,
            ),
            onTap: max == null ? null : () => controller.setArmed(!toggle.armed),
          ),
          if (max == null && access.hasValue)
            PopoverRow(
              key: const ValueKey('ultra.upgrade'),
              title: 'See plans…',
              onTap: () {
                close();
                context.go(Routes.billing);
              },
            ),
          if (max != null) ...[
            const PopoverHeader('Caps for the next run'),
            CapStepper(
              key: const ValueKey('ultra.cap.concurrent'),
              label: 'At once',
              value: '${l.maxConcurrent} agents',
              onStep: (dir) => set(
                (l) => _with(
                  l,
                  concurrent: UltraCapSteps.next(UltraCapSteps.concurrent, l.maxConcurrent, dir, max.maxConcurrent),
                ),
              ),
            ),
            CapStepper(
              key: const ValueKey('ultra.cap.agents'),
              label: 'In total',
              value: '${l.maxAgents} agents',
              onStep: (dir) => set(
                (l) => _with(l, agents: UltraCapSteps.next(UltraCapSteps.agents, l.maxAgents, dir, max.maxAgents)),
              ),
            ),
            CapStepper(
              key: const ValueKey('ultra.cap.dollars'),
              label: 'Spend',
              value: formatMicros(l.budgetMicros),
              onStep: (dir) => set(
                (l) => _with(
                  l,
                  budgetMicros:
                      UltraCapSteps.next(
                        UltraCapSteps.dollars,
                        (l.budgetMicros / 1e6).ceil(),
                        dir,
                        max.budgetMicros ~/ 1000000,
                      ) *
                      1000000,
                ),
              ),
            ),
            CapStepper(
              key: const ValueKey('ultra.cap.wall'),
              label: 'Wall time',
              value: formatUltraDuration(l.wallTime),
              onStep: (dir) => set(
                (l) => _with(
                  l,
                  wall: Duration(
                    minutes: UltraCapSteps.next(
                      UltraCapSteps.wallMinutes,
                      l.wallTime.inMinutes,
                      dir,
                      max.wallTime.inMinutes,
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
              child: Text(
                'Opus plans and does the hard steps; easy ones go to Sonnet or Haiku. '
                'Your plan allows up to ${max.maxConcurrent} at once, ${max.maxAgents} in total, '
                '${formatMicros(max.budgetMicros)} and ${formatUltraDuration(max.wallTime)}.',
                style: TextStyle(color: theme.textMuted, fontSize: 11.5),
              ),
            ),
            PopoverRow(key: const ValueKey('ultra.reset'), title: 'Reset to the plan’s caps', onTap: controller.reset),
          ],
          if (running > 0)
            PopoverRow(
              key: const ValueKey('ultra.stop-all'),
              title: running == 1 ? 'Stop the Ultra run' : 'Stop all $running Ultra runs',
              destructive: true,
              onTap: () {
                close();
                stopUltraRuns(ref, sessionId);
              },
            ),
        ],
      ),
    );
  }

  static UltraLimits _with(UltraLimits l, {int? concurrent, int? agents, int? budgetMicros, Duration? wall}) =>
      UltraLimits(
        maxConcurrent: concurrent ?? l.maxConcurrent,
        maxAgents: agents ?? l.maxAgents,
        budgetMicros: budgetMicros ?? l.budgetMicros,
        wallTime: wall ?? l.wallTime,
        verifyRetries: l.verifyRetries,
        maxPhases: l.maxPhases,
        maxStepsPerPhase: l.maxStepsPerPhase,
        maxItems: l.maxItems,
      );
}

/// A cap's row: its label, value, and − / + to step through the presets.
class CapStepper extends StatelessWidget {
  const CapStepper({super.key, required this.label, required this.value, required this.onStep});

  final String label;
  final String value;
  final ValueChanged<int> onStep;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    Widget button(String glyph, int dir, String tip) => Semantics(
      button: true,
      label: '$tip $label',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          key: ValueKey('$glyph$label'),
          behavior: HitTestBehavior.opaque,
          onTap: () => onStep(dir),
          child: Container(
            width: 24,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border.all(color: theme.border),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(glyph, style: TextStyle(color: theme.text, fontSize: 14, height: 1)),
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: TextStyle(color: theme.text, fontSize: 13)),
          ),
          button('−', -1, 'Lower'),
          SizedBox(
            width: 78,
            child: Text(
              value,
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.text, fontSize: 12.5, fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ),
          button('+', 1, 'Raise'),
        ],
      ),
    );
  }
}

/// A line above the composer while Ultra is on, so the next send isn't a
/// surprise: the caps, and a way to turn it off.
class UltraComposerBanner extends ConsumerWidget {
  const UltraComposerBanner({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final toggle = ref.watch(ultraToggleProvider(sessionId));
    if (!toggle.armed) return const SizedBox.shrink();
    final theme = EveryTheme.of(context);
    final l = toggle.limits;
    return Container(
      key: const ValueKey('ultra.banner'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: theme.accent.withValues(alpha: 0.08),
        border: Border.all(color: theme.accent.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          AdaptiveIcon(EveryIcon.spark, size: 14, color: theme.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Ultra is on: your next message starts a run with up to ${l.maxAgents} agents '
              '(${l.maxConcurrent} at once), ${formatMicros(l.budgetMicros)} and ${formatUltraDuration(l.wallTime)}.',
              style: TextStyle(color: theme.text, fontSize: 12.5),
            ),
          ),
          AdaptiveButton(
            label: 'Turn off',
            emphasis: ButtonEmphasis.plain,
            onPressed: () => ref.read(ultraToggleProvider(sessionId).notifier).setArmed(false),
          ),
        ],
      ),
    );
  }
}

/// `45s`, `3m 05s`, `1h 02m`, `2h`.
String formatUltraDuration(Duration d) {
  if (d.inHours > 0) {
    final m = d.inMinutes % 60;
    return m == 0 ? '${d.inHours}h' : '${d.inHours}h ${m.toString().padLeft(2, '0')}m';
  }
  if (d.inMinutes > 0) {
    final s = d.inSeconds % 60;
    return d.inSeconds % 60 == 0 && d.inMinutes >= 5
        ? '${d.inMinutes}m'
        : '${d.inMinutes}m ${s.toString().padLeft(2, '0')}s';
  }
  return '${d.inSeconds}s';
}
