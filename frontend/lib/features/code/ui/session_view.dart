import '../../../core/ui/brand.dart';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/adaptive_page.dart';
import '../../../core/ui/every_icons.dart';
import '../../../core/ui/selection.dart';
import '../../models/domain/model_catalog.dart';
import '../../models/models_providers.dart';
import '../../usage/ui/usage_meter.dart';
import '../../usage/usage_totals.dart';
import '../code_providers.dart';
import '../domain/agent_mode.dart';
import '../domain/code_session.dart';
import '../domain/questions.dart';
import '../domain/transcript.dart';
import 'code_composer.dart';
import 'transcript/approval_card.dart';
import 'transcript/plan_card.dart';
import 'transcript/question_card.dart';
import 'transcript/transcript_items.dart';

const _maxWidth = 780.0;

/// One coding session: the transcript, the approval/question surface and
/// the composer.
class CodeSessionScreen extends ConsumerWidget {
  const CodeSessionScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final info = ref.watch(codeSessionsProvider.select((all) => all.where((s) => s.id == sessionId).firstOrNull));
    if (info == null) {
      return AdaptivePage(
        title: 'Code',
        body: Center(
          child: Text('This session no longer exists.', style: TextStyle(color: theme.textMuted)),
        ),
      );
    }
    final provider = codeSessionProvider(sessionId);
    final state = ref.watch(provider);
    final controller = ref.read(provider.notifier);
    final t = state.transcript;
    final busy = t.running || t.pending.isNotEmpty;

    final showStartBuilding =
        state.mode == AgentMode.plan &&
        !busy &&
        t.openQuestion == null &&
        t.items.whereType<PlanProposal>().isEmpty &&
        t.items.lastOrNull is AgentText &&
        t.items.whereType<UserTurn>().isNotEmpty;

    return AdaptivePage(
      title: info.title,
      actions: [
        StatusPill(status: state.status),
        AdaptiveIconButton(icon: EveryIcon.newChat, tooltip: 'New session', onPressed: () => context.go(Routes.code)),
      ],
      body: Column(
        children: [
          Expanded(
            child: _TranscriptList(
              transcript: t,
              onAnswer: controller.answer,
              mode: state.mode,
              onApprovePlan: controller.startBuilding,
              onRevisePlan: controller.send,
            ),
          ),
          if (state.error case final error?)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: NoticeView(item: NoticeItem('error', error, error: true)),
            )
          else if (!state.connected && t.items.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: NoticeView(item: const NoticeItem('reconnecting', 'Reconnecting to the agent server…')),
            ),
          SafeArea(
            top: false,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _maxWidth),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (t.pending.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: ApprovalCard(
                            key: ValueKey(t.pending.map((c) => c.id).join()),
                            pending: t.pending,
                            mode: state.mode,
                            onAllow: controller.approve,
                            onDeny: controller.deny,
                            onMode: controller.setMode,
                          ),
                        )
                      else if (t.plan.isNotEmpty && t.running)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: PlanView(tasks: t.plan, compact: true),
                        ),
                      if (showStartBuilding)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _StartBuilding(onStart: controller.startBuilding),
                        ),
                      CodeComposer(
                        busy: busy,
                        mode: state.mode,
                        onModeChanged: controller.setMode,
                        onSend: (text, files) => controller.send(text, files: files),
                        onSteer: (text, files) => controller.steer(text, files: files),
                        onStop: controller.stop,
                        queued: [for (final q in state.queued) q.text],
                        onUnqueue: controller.unqueue,
                        placeholder: t.openQuestion != null
                            ? 'Answer the questions above, or reply in your own words'
                            : 'Ask for a change, or reply to the agent',
                        trailing: Text(
                          info.model.split('/').last,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: theme.textMuted, fontSize: 12.5),
                        ),
                        model: ref.watch(modelCatalogProvider)[ModelId(info.model)],
                        meter: UsageMeter(
                          totals: ref.watch(codeUsageProvider(sessionId)).value ?? UsageTotals.zero,
                          contextWindow: ref.watch(modelCatalogProvider)[ModelId(info.model)]?.contextLength ?? 0,
                          modelName: ref.watch(modelCatalogProvider)[ModelId(info.model)]?.name,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TranscriptList extends StatelessWidget {
  const _TranscriptList({
    required this.transcript,
    required this.mode,
    required this.onAnswer,
    required this.onApprovePlan,
    required this.onRevisePlan,
  });

  final Transcript transcript;
  final AgentMode mode;
  final void Function(QuestionItem, List<QuestionAnswer>) onAnswer;
  final VoidCallback onApprovePlan;
  final ValueChanged<String> onRevisePlan;

  @override
  Widget build(BuildContext context) {
    final t = transcript;
    final live = t.streaming.isNotEmpty || t.streamingReasoning.isNotEmpty;
    // Newest at the bottom; a reversed list keeps the view pinned there.
    final children = <Widget>[
      if (live)
        AgentTextView(text: t.streaming, reasoning: t.streamingReasoning, streaming: true)
      else if (t.running)
        const _Working(),
      for (final item in t.items.reversed) _itemView(item),
    ];
    return AdaptiveSelectionArea(
      child: ListView.builder(
        reverse: true,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        itemCount: children.length,
        itemBuilder: (context, i) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _maxWidth),
            child: Padding(padding: const EdgeInsets.symmetric(vertical: 5), child: children[i]),
          ),
        ),
      ),
    );
  }

  Widget _itemView(TranscriptItem item) => switch (item) {
    UserTurn(:final text, :final mode) => Padding(
      padding: const EdgeInsets.only(top: 10),
      child: UserTurnView(text: text, mode: mode),
    ),
    AgentText(:final text, :final reasoning) => AgentTextView(text: text, reasoning: reasoning),
    ExploreGroup() => ExploreGroupView(group: item),
    StepItem(:final step) => StepView(step: step),
    SubagentItem() => SubagentView(item: item),
    PlanItem(:final tasks) => PlanView(tasks: tasks),
    QuestionItem() => QuestionCard(
      key: ValueKey(item.key),
      item: item,
      enabled: item == transcript.openQuestion,
      onSubmit: (answers) => onAnswer(item, answers),
    ),
    PlanProposal() => PlanCard(
      key: ValueKey(item.key),
      plan: item,
      open: item == transcript.openPlan,
      switchesToAutoEdit: mode == AgentMode.plan,
      onApprove: onApprovePlan,
      onRevise: onRevisePlan,
    ),
    NoticeItem() => NoticeView(item: item),
  };
}

class _Working extends StatelessWidget {
  const _Working();

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Row(
      children: [
        const EveryMarkActivity(size: 16),
        const SizedBox(width: 10),
        Text('Working…', style: TextStyle(color: theme.textMuted, fontSize: 13)),
      ],
    );
  }
}

class _StartBuilding extends StatelessWidget {
  const _StartBuilding({required this.onStart});
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      decoration: BoxDecoration(
        color: theme.accent.withValues(alpha: 0.08),
        border: Border.all(color: theme.accent.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(EveryTheme.cardRadius),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Happy with the plan? Start building switches to Auto-edit.',
              style: TextStyle(color: theme.text, fontSize: 13),
            ),
          ),
          AdaptiveButton(label: 'Start building', onPressed: onStart),
        ],
      ),
    );
  }
}

/// A coloured dot and label for a session's status.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.status, this.dense = false});
  final SessionStatus status;
  final bool dense;

  static Color colorOf(SessionStatus s, EveryTheme theme) => switch (s) {
    SessionStatus.running || SessionStatus.starting => theme.accent,
    SessionStatus.needsInput => theme.warning,
    SessionStatus.failed => theme.danger,
    SessionStatus.done => theme.success,
    SessionStatus.idle => theme.textMuted,
  };

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final color = colorOf(status, theme);
    final dot = Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
    if (dense) return Semantics(label: status.label, child: dot);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          dot,
          const SizedBox(width: 6),
          Text(status.label, style: TextStyle(color: theme.textMuted, fontSize: 12.5)),
        ],
      ),
    );
  }
}
