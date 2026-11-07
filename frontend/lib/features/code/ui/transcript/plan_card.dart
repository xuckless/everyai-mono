import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../../core/motion/motion.dart';
import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/layout.dart';
import '../../../../core/ui/every_icons.dart';
import '../../../chat/ui/chat_markdown.dart';
import '../../domain/transcript.dart';

final _mono = EveryType.resolve().caption.mono.copyWith(height: 1.4);

/// The agent's `present_plan` proposal: numbered steps with the files they
/// touch, risks, and how it will verify. While [open], the user can start
/// building or send it back with changes.
class PlanCard extends StatefulWidget {
  const PlanCard({
    super.key,
    required this.plan,
    required this.open,
    required this.onApprove,
    required this.onRevise,
    this.switchesToAutoEdit = false,
  });

  final PlanProposal plan;
  final bool open;

  /// In Plan mode, approving moves the session to Auto-edit.
  final bool switchesToAutoEdit;

  /// Each may return `false` or a `Future<bool>` of false when nothing was sent (a spent budget): the card opens
  /// again. `dynamic` so plain `void` callbacks still fit.
  final dynamic Function() onApprove;
  final dynamic Function(String text) onRevise;

  @override
  State<PlanCard> createState() => _PlanCardState();
}

class _PlanCardState extends State<PlanCard> {
  final _feedback = TextEditingController();
  bool _revising = false;

  /// Answering the plan:
  ///
  /// ```text
  ///  open ──Start building / Revise──► sent ──refused (false)──► open
  /// ```
  bool _sent = false;

  @override
  void dispose() {
    _feedback.dispose();
    super.dispose();
  }

  void _approve() {
    if (_sent) return;
    setState(() => _sent = true);
    _settle(widget.onApprove());
  }

  void _revise() {
    final text = _feedback.text.trim();
    if (text.isEmpty || _sent) return;
    setState(() => _sent = true);
    _settle(widget.onRevise(text));
  }

  /// Opens the card again when the answer didn't go out.
  void _settle(Object? sent) {
    void reopen() {
      if (mounted) setState(() => _sent = false);
    }

    if (sent is Future<bool>) {
      sent.then((ok) => ok ? null : reopen(), onError: (Object _) => reopen());
    } else if (sent == false) {
      reopen();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final plan = widget.plan;
    final open = widget.open && !_sent;
    final steps = plan.steps;
    final risks = plan.risks;
    final fileCount = {for (final st in steps) ...st.files}.length;

    return Container(
      decoration: BoxDecoration(
        color: theme.surfaceRaised,
        border: Border.all(color: theme.border),
        borderRadius: BorderRadius.circular(EveryTheme.cardRadius),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  plan.title.isEmpty ? 'Plan' : plan.title,
                  style: theme.type.callout.semibold.tint(theme.text),
                ),
              ),
              if (steps.isNotEmpty)
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Text(
                      [
                        '${steps.length} ${steps.length == 1 ? 'step' : 'steps'}',
                        if (fileCount > 0) '$fileCount ${fileCount == 1 ? 'file' : 'files'}',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.type.caption.tint(theme.textSubtle),
                    ),
                  ),
                ),
              if (plan.verdict case final verdict?)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Text(
                    verdict == PlanVerdict.approved ? 'Approved' : 'Sent back',
                    style: theme.type.caption.semibold.tint(
                      verdict == PlanVerdict.approved ? theme.success : theme.textMuted,
                    ),
                  ),
                ),
              AdaptiveIconButton(
                icon: EveryIcon.copy,
                tooltip: 'Copy plan',
                size: 15,
                onPressed: () => Clipboard.setData(ClipboardData(text: plan.markdown)),
              ),
            ],
          ),
          if (plan.summary.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(plan.summary, style: theme.type.callout.copyWith(color: theme.textMuted, height: 1.4)),
          ],
          if (plan.body.trim().isNotEmpty) ...[const SizedBox(height: 8), ChatMarkdown(plan.body.trim())],
          const SizedBox(height: 10),
          for (final (i, step) in steps.indexed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(padding: EdgeInsets.only(top: 6, right: 12), child: StatusDot(DotStatus.idle)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(step.title, style: theme.type.callout.copyWith(color: theme.text, height: 1.4)),
                        if (step.detail.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 1),
                            child: Text(
                              step.detail,
                              style: theme.type.caption.copyWith(color: theme.textSubtle, height: 1.35),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (step.files.isNotEmpty)
                    Flexible(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 12, top: 2),
                        child: Align(
                          alignment: Alignment.topRight,
                          child: Text(
                            step.files.join('  '),
                            textAlign: TextAlign.end,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: _mono.copyWith(color: theme.textSubtle),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ).settle(delay: Duration(milliseconds: 30 * i)),
          if (risks.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('Risks', style: theme.type.callout.semibold.tint(theme.text)),
            const SizedBox(height: 3),
            for (final r in risks)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text('•  $r', style: theme.type.callout.copyWith(color: theme.textMuted, height: 1.35)),
              ),
          ],
          if (plan.verification.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: 'Verify: ',
                    style: TextStyle(color: theme.text, fontWeight: FontWeight.w600),
                  ),
                  TextSpan(text: plan.verification),
                ],
              ),
              style: theme.type.callout.copyWith(color: theme.textMuted, height: 1.35),
            ),
          ],
          if (open) ...[
            const SizedBox(height: 12),
            if (_revising) ...[
              AdaptiveTextField(
                controller: _feedback,
                placeholder: 'What should change?',
                autofocus: true,
                minLines: 1,
                maxLines: 4,
                onSubmitted: (_) => _revise(),
              ),
              const SizedBox(height: 8),
            ],
            WrapRow(
              lead: Text(
                widget.switchesToAutoEdit ? 'Switches to Auto-edit' : '',
                style: theme.type.caption.tint(theme.textSubtle),
              ),
              actions: [
                if (_revising)
                  KitButton(label: 'Send changes', style: KitButtonStyle.ghost, onPressed: _revise)
                else
                  KitButton(
                    label: 'Keep planning',
                    style: KitButtonStyle.ghost,
                    onPressed: () => setState(() => _revising = true),
                  ),
                KitButton(label: 'Start building', onPressed: _approve),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
