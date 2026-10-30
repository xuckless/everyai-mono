import 'package:everyai_markdown/everyai_markdown.dart' show languageForPath;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/every_icons.dart';
import '../../../../core/ui/syntax_spans.dart';
import '../../domain/agent_mode.dart';
import '../../domain/line_diff.dart';
import '../../domain/permissions.dart';
import '../../domain/transcript.dart';
import '../../harness/events.dart';
import 'transcript_items.dart';

/// Actions waiting for the user: what will run, and Allow (once, for the
/// session, always) / Deny.
class ApprovalCard extends StatefulWidget {
  const ApprovalCard({
    super.key,
    required this.pending,
    required this.mode,
    required this.onAllow,
    required this.onDeny,
    required this.onMode,
    this.remember,
    this.flags = const {},
  });

  final List<ActionCall> pending;
  final AgentMode mode;
  final ValueChanged<ApprovalScope> onAllow;
  final ValueChanged<String> onDeny;
  final ValueChanged<AgentMode> onMode;

  /// The rules "for this session" / "always" would store; null hides those
  /// buttons (compound commands and dangerous actions are approved once).
  final List<String>? remember;

  /// Why an action needs a look, by call id (from the danger classifier).
  final Map<String, String> flags;

  @override
  State<ApprovalCard> createState() => _ApprovalCardState();
}

class _ApprovalCardState extends State<ApprovalCard> {
  final _reason = TextEditingController();
  bool _denying = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final calls = widget.pending;
    final edits = calls.every((c) => c.actionKind == 'FileEditorAction' && c.str('command') != 'view');
    final remember = widget.remember;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): () => widget.onAllow(ApprovalScope.once),
        const SingleActivator(LogicalKeyboardKey.escape): () => setState(() => _denying = true),
      },
      child: Focus(
        autofocus: true,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: theme.surfaceRaised,
            border: Border.all(color: theme.warning.withValues(alpha: 0.7)),
            borderRadius: BorderRadius.circular(EveryTheme.cardRadius),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                calls.length == 1 ? approvalTitle(calls.single) : 'Allow ${calls.length} actions?',
                style: TextStyle(color: theme.text, fontSize: 14, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [for (final c in calls) _Preview(call: c, flag: widget.flags[c.id])],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              if (_denying) ...[
                AdaptiveTextField(
                  controller: _reason,
                  autofocus: true,
                  placeholder: 'Tell the agent what to do instead (optional)',
                  onSubmitted: (_) => widget.onDeny(_reason.text),
                ),
                const SizedBox(height: 8),
              ],
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.end,
                children: [
                  if (_denying)
                    AdaptiveButton(
                      label: 'Deny',
                      emphasis: ButtonEmphasis.destructive,
                      onPressed: () => widget.onDeny(_reason.text),
                    )
                  else
                    AdaptiveButton(
                      label: 'Deny…',
                      emphasis: ButtonEmphasis.secondary,
                      onPressed: () => setState(() => _denying = true),
                    ),
                  if (widget.mode == AgentMode.ask && edits)
                    AdaptiveButton(
                      label: 'Allow all edits',
                      emphasis: ButtonEmphasis.secondary,
                      onPressed: () => widget.onMode(AgentMode.autoEdit),
                    ),
                  if (remember != null) ...[
                    AdaptiveButton(
                      label: 'Always allow',
                      emphasis: ButtonEmphasis.secondary,
                      onPressed: () => widget.onAllow(ApprovalScope.always),
                    ),
                    AdaptiveButton(
                      label: 'Allow for session',
                      emphasis: ButtonEmphasis.secondary,
                      onPressed: () => widget.onAllow(ApprovalScope.session),
                    ),
                  ],
                  AdaptiveButton(label: 'Allow once  ⌘↩', onPressed: () => widget.onAllow(ApprovalScope.once)),
                ],
              ),
              if (remember != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Session and always cover: ${remember.join(', ')}',
                    textAlign: TextAlign.end,
                    style: TextStyle(color: theme.textMuted, fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.call, this.flag});
  final ActionCall call;
  final String? flag;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    const mono = TextStyle(fontFamily: 'SourceCodePro', fontSize: 12.5, height: 1.45);
    final risk = call.risk.toUpperCase();
    final body = switch (call.actionKind) {
      'TerminalAction' => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: theme.codeBackground, borderRadius: BorderRadius.circular(8)),
        child: Text.rich(
          TextSpan(
            style: mono.copyWith(color: theme.text),
            children: [
              TextSpan(
                text: '\$ ',
                style: TextStyle(color: theme.textMuted),
              ),
              shellSpan(
                call.str('command'),
                base: mono.copyWith(color: theme.text),
                brightness: theme.brightness,
              ),
            ],
          ),
        ),
      ),
      'FileEditorAction' when call.str('command') != 'view' => DiffBlock(
        lines: lineDiff(call.str('old_str'), call.str('new_str').isEmpty ? call.str('file_text') : call.str('new_str')),
        maxLines: 24,
        language: languageForPath(call.str('path')),
      ),
      _ => Text(stepTitle(call), style: TextStyle(color: theme.textMuted, fontSize: 13)),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          body,
          if (flag case final why?)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  AdaptiveIcon(EveryIcon.close, size: 12, color: theme.danger),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      'Needs a look: this ${why.replaceFirst(RegExp(r'^an? '), '')}',
                      style: TextStyle(color: theme.danger, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          if (risk == 'HIGH' || risk == 'MEDIUM')
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  AdaptiveIcon(EveryIcon.close, size: 12, color: risk == 'HIGH' ? theme.danger : theme.textMuted),
                  const SizedBox(width: 4),
                  Text(
                    'The agent rates this ${risk.toLowerCase()} risk',
                    style: TextStyle(color: risk == 'HIGH' ? theme.danger : theme.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
