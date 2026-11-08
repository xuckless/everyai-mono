// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/widgets.dart';

import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../ui/console/session_info_view.dart' show planWindowName;
import '../workflow_estimate.dart';
import '../workflow_proposal.dart';

/// The card a workflow run waits on above the composer: its phases, items and estimate, with Start, Adjust and
/// Cancel (owner, 2026-11-08). Time is shown as information; the cap only on an EveryAI lead.
///
/// One answer at a time: [_answer] is idle → answering, and a second click while one is on its way does nothing.
class ProposalCard extends StatefulWidget {
  const ProposalCard({
    super.key,
    required this.proposal,
    required this.onStart,
    required this.onAdjust,
    required this.onCancel,
  });

  final WorkflowProposal proposal;
  final Future<void> Function() onStart;
  final VoidCallback onAdjust;
  final VoidCallback onCancel;

  @override
  State<ProposalCard> createState() => _ProposalCardState();
}

enum _Answer { idle, answering }

class _ProposalCardState extends State<ProposalCard> {
  var _answer = _Answer.idle;

  Future<void> _go(Future<void> Function() action) async {
    if (_answer == _Answer.answering) return;
    setState(() => _answer = _Answer.answering);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _answer = _Answer.idle);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final p = widget.proposal;
    final e = p.estimate;
    final line = estimateLine(e);
    final busy = _answer == _Answer.answering;
    return Container(
      key: ValueKey('workflow-proposal.${p.id}'),
      decoration: BoxDecoration(
        color: theme.surfaceRaised,
        border: Border.all(color: theme.border),
        borderRadius: BorderRadius.circular(EveryTheme.cardRadius),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            [
              p.title,
              if (p.items.isNotEmpty) '${p.items.length} ${p.items.length == 1 ? 'item' : 'items'}',
            ].join(' · '),
            style: theme.type.callout.semibold.tint(theme.text),
          ),
          if (p.phases.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(p.phases.join(' → '), style: theme.type.caption.tint(theme.textMuted)),
          ],
          if (p.items.isNotEmpty) ...[
            const SizedBox(height: 6),
            for (final it in p.items.take(8))
              Text('• $it', maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.type.caption.tint(theme.text)),
            if (p.items.length > 8)
              Text('and ${p.items.length - 8} more', style: theme.type.caption.tint(theme.textMuted)),
          ],
          const SizedBox(height: 8),
          Text(
            line.isEmpty ? 'No estimate: this workflow doesn\'t say how many agents it starts.' : line,
            key: const ValueKey('workflow-proposal.estimate'),
            style: theme.type.callout.mono.tint(theme.text),
          ),
          for (final w in e.planWindows)
            Text(
              '${planWindowName(w)}: ${(w.used * 100).round()}% used',
              style: theme.type.caption.tint(theme.textMuted),
            ),
          Text(
            [
              if (p.capUsd case final cap?) 'Cap \$${cap.toStringAsFixed(0)}' else 'No money cap (your subscription)',
              if (e.time != null) 'time from past runs, not a limit',
              // The items aren't known yet, so there is no total to check the spend against.
              if (e.dollars != null && e.ceilingMicros == null) 'no spending checkpoints (items not known yet)',
              if (e.basis.isNotEmpty) e.basis,
            ].join(' · '),
            style: theme.type.caption.tint(theme.textSubtle),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              AdaptiveButton(
                key: const ValueKey('workflow-proposal.cancel'),
                label: 'Cancel',
                emphasis: ButtonEmphasis.plain,
                onPressed: busy ? null : widget.onCancel,
              ),
              const SizedBox(width: 6),
              AdaptiveButton(
                key: const ValueKey('workflow-proposal.adjust'),
                label: 'Adjust',
                emphasis: ButtonEmphasis.plain,
                onPressed: busy ? null : widget.onAdjust,
              ),
              const SizedBox(width: 6),
              AdaptiveButton(
                key: const ValueKey('workflow-proposal.start'),
                label: 'Start',
                onPressed: busy ? null : () => _go(widget.onStart),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
