import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/widgets.dart';

import '../../../../core/motion/motion.dart';
import '../../../../core/theme/every_theme.dart';
import '../../domain/plan_report.dart';

/// An outside harness's plan report ([parsePlanReport]) drawn with the kit: limits as bars, the usage breakdown as
/// rows with their share, top lists as pills. A report with nothing recognisable shows as its text.
class PlanReportView extends StatelessWidget {
  const PlanReportView(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final parts = parsePlanReport(text);
    if (parts.every((p) => p is PlanNote)) {
      return SelectableText(text.trim(), style: theme.type.callout.mono.tint(theme.textMuted));
    }
    final children = <Widget>[];
    PlanReportPart? last;
    for (final part in parts) {
      // A little more air between groups of different kinds than inside a group.
      if (last != null) {
        final gap = part is PlanLimit && last is PlanLimit ? 12.0 : (part.runtimeType == last.runtimeType ? 8.0 : 14.0);
        children.add(SizedBox(height: gap));
      }
      children.add(switch (part) {
        PlanNote(:final text) => Text(text, style: theme.type.callout.tint(theme.textMuted)),
        PlanLimit() => _LimitRow(part),
        PlanHeading(:final text, :final caption) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(text, style: theme.type.callout.semibold.tint(theme.text)),
            if (caption != null) Text(caption, style: theme.type.caption.tint(theme.textSubtle)),
          ],
        ),
        PlanPeriod(:final label, :final facts) => Text.rich(
          TextSpan(
            children: [
              TextSpan(text: label, style: theme.type.caption.medium.tint(theme.textMuted)),
              for (final f in facts) ...[
                TextSpan(text: '  ·  ', style: theme.type.caption.tint(theme.textSubtle)),
                TextSpan(text: f, style: theme.type.caption.mono.tint(theme.textMuted)),
              ],
            ],
          ),
        ),
        PlanShare() => _ShareRow(part),
        PlanTop() => _TopRow(part),
      });
      last = part;
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: children);
  }
}

/// "This week · all models", "63% used" in mono, a bar, and when it resets.
class _LimitRow extends StatelessWidget {
  const _LimitRow(this.limit);
  final PlanLimit limit;

  @override
  Widget build(BuildContext context) =>
      PlanLimitBar(label: limit.label, scope: limit.scope, percent: limit.percent, resets: limit.resets);
}

/// A plan limit as a labelled bar: [label] and [scope], the percent used in mono, a bar that turns amber at 75% and
/// red at 90%, and [resets] under it. [compact] is the Board's strip (smaller type, thinner bar).
class PlanLimitBar extends StatelessWidget {
  const PlanLimitBar({
    super.key,
    required this.label,
    required this.percent,
    this.scope,
    this.resets,
    this.compact = false,
  });

  final String label;
  final String? scope;
  final int percent;
  final String? resets;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final color = planLimitColor(theme, percent);
    final labelStyle = compact
        ? theme.type.caption.medium.tint(theme.text)
        : theme.type.callout.medium.tint(theme.text);
    final scopeStyle = compact ? theme.type.caption.tint(theme.textMuted) : theme.type.callout.tint(theme.textMuted);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: label, style: labelStyle),
                    if (scope case final s?) TextSpan(text: '  ·  $s', style: scopeStyle),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text('$percent% used', style: theme.type.caption.mono.tint(theme.textMuted)),
          ],
        ),
        SizedBox(height: compact ? 4 : 6),
        _Bar(fraction: percent / 100, color: color, height: compact ? 3 : 5),
        if (resets case final r?) ...[
          SizedBox(height: compact ? 2 : 4),
          Text(
            _capitalise(r),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.type.caption.tint(theme.textSubtle),
          ),
        ],
      ],
    );
  }
}

/// A limit's colour: the accent, amber from 75% used, red from 90%.
Color planLimitColor(EveryTheme theme, int percent) => percent >= 90
    ? theme.danger
    : percent >= 75
    ? theme.warning
    : theme.accent;

/// A share of usage: the percent in mono beside a short bar, the advice, and its detail under it.
class _ShareRow extends StatelessWidget {
  const _ShareRow(this.share);
  final PlanShare share;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 44,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${share.percent}%', style: theme.type.callout.mono.tint(theme.text)),
              const SizedBox(height: 4),
              SizedBox(
                width: 32,
                child: _Bar(fraction: share.percent / 100, color: theme.accent, height: 3),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(share.text, style: theme.type.callout.tint(theme.text)),
              if (share.detail case final d?) Text(_capitalise(d), style: theme.type.caption.tint(theme.textMuted)),
            ],
          ),
        ),
      ],
    );
  }
}

/// "Top subagents" and its items as quiet pills (name, share in mono).
class _TopRow extends StatelessWidget {
  const _TopRow(this.top);
  final PlanTop top;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(top.label, style: theme.type.caption.medium.tint(theme.textMuted)),
        const SizedBox(height: 5),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final item in top.items)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: theme.text.withValues(alpha: 0.05),
                  border: Border.all(color: theme.border),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: item.name, style: theme.type.caption.tint(theme.text)),
                      if (item.share case final s?)
                        TextSpan(text: '  $s', style: theme.type.caption.mono.tint(theme.textMuted)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.fraction, required this.color, required this.height});
  final double fraction;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(99),
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: theme.border)),
            Positioned.fill(
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: fraction.clamp(0, 1)),
                duration: Motion.reduced(context) ? Duration.zero : const Duration(milliseconds: 520),
                curve: Motion.easeOut,
                builder: (context, v, _) => FractionallySizedBox(
                  widthFactor: v,
                  heightFactor: 1,
                  alignment: Alignment.centerLeft,
                  child: ColoredBox(color: color),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _capitalise(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
