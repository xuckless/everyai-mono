import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../../models/domain/model_catalog.dart';
import '../../models/models_providers.dart';
import '../code_providers.dart';
import '../domain/session_work.dart';
import '../ui/code_composer.dart';
import '../ui/code_slash_host.dart';
import '../ui/harness_logo.dart';
import '../ui/session_view.dart' show StatusPill, TranscriptList;
import '../ui/transcript/session_approval.dart';
import '../ui/transcript/transcript_items.dart' show TranscriptScope;
import '../../usage/usage_totals.dart' show UsageTotals;
import 'board_limits.dart' show boardCostLine;
import 'board_state.dart';
import 'board_work.dart';

/// One session beside the Board: its header, its forks and subagents, the conversation (newest at the bottom, following
/// as it grows), its approvals, and a composer to reply, steer or stop, all on the session's own controller. Opening
/// it counts as looking at the session ([markBoardSeen]).
class BoardInspectorPane extends ConsumerWidget {
  const BoardInspectorPane({
    super.key,
    required this.sessionId,
    required this.onClose,
    required this.onOpenFull,
    this.cover = false,
    this.focusComposer = false,
    this.draft,
    this.onDraftChanged,
  });

  final String sessionId;

  /// Opened by a click: the composer takes the keys, so a reply typed at once is text, not Board keys. Opened from
  /// the keyboard, the Board keeps them.
  final bool focusComposer;

  /// The reply typed earlier and not sent (kept by the Board when the pane closes or moves), and its changes.
  final String? draft;
  final ValueChanged<String>? onDraftChanged;

  /// It covers the Board (a narrow window): the close control reads as Back.
  final bool cover;
  final VoidCallback onClose;
  final VoidCallback onOpenFull;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final info = ref.watch(codeSessionsProvider.select((all) => all.where((s) => s.id == sessionId).firstOrNull));
    if (info == null) return const SizedBox.shrink();
    final provider = codeSessionProvider(sessionId);
    final state = ref.watch(provider);
    final controller = ref.read(provider.notifier);
    final t = state.transcript;
    final busy = t.running || t.pending.isNotEmpty;
    final work = controller.runningWork;
    // Looking here is looking at the session: its finish no longer shows as new on the card.
    final seen = seenUpdate(status: state.status, connected: state.connected, sideWork: hasSideWork(work));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted) markBoardSeen(ref, sessionId, seen);
    });
    final model = ref.watch(modelCatalogProvider)[ModelId(info.model)];
    // What it cost so far, as on its card (read when the session's meter is already up; never started for this).
    final cost = ref.exists(codeUsageProvider(sessionId))
        ? boardCostLine(ref.watch(codeUsageProvider(sessionId)).value ?? UsageTotals.zero)
        : '';
    final modelName = model?.name ?? info.model;

    return Column(
      key: ValueKey('board.inspector.$sessionId'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Row(
            children: [
              if (cover) ...[
                KitIconButton(
                  key: const ValueKey('board.inspector.back'),
                  icon: EveryIcon.chevronLeft,
                  tooltip: 'Back to the Board',
                  size: 16,
                  onPressed: onClose,
                ),
                const SizedBox(width: 4),
              ],
              HarnessLogo(info.harness, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      info.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.type.callout.semibold.tint(theme.text),
                    ),
                    if (modelName.isNotEmpty || cost.isNotEmpty)
                      Text.rich(
                        TextSpan(
                          children: [
                            if (modelName.isNotEmpty) TextSpan(text: modelName),
                            if (modelName.isNotEmpty && cost.isNotEmpty) const TextSpan(text: '  ·  '),
                            if (cost.isNotEmpty)
                              TextSpan(text: cost, style: theme.type.caption.mono.tint(theme.textSubtle)),
                          ],
                        ),
                        key: const ValueKey('board.inspector.meta'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.type.caption.tint(theme.textSubtle),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              StatusPill(status: state.status, dense: true),
              const SizedBox(width: 4),
              KitButton(
                key: const ValueKey('board.inspector.open'),
                label: 'Open',
                style: KitButtonStyle.ghost,
                onPressed: onOpenFull,
              ),
              if (!cover)
                KitIconButton(
                  key: const ValueKey('board.inspector.close'),
                  icon: EveryIcon.close,
                  tooltip: 'Close (Esc)',
                  size: 16,
                  onPressed: onClose,
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: BoardWork(sessionId: sessionId),
        ),
        const SizedBox(height: 4),
        Container(height: 1, color: theme.border),
        Expanded(
          child: TranscriptScope(
            root: info.workingDir,
            child: TranscriptList(
              onRewind: null,
              transcript: t,
              onAnswer: controller.answer,
              onAnswerWithFiles: (item, a, files) => controller.answer(item, a, files: files),
              acceptsFiles: controller.acceptsFiles,
              model: model,
              mode: state.mode,
              onApprovePlan: controller.startBuilding,
              onRevisePlan: controller.send,
              onRetry: controller.retry,
              sessionId: sessionId,
              workingDir: info.workingDir,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Its approvals, Allow or Deny per call.
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: SingleChildScrollView(child: SessionApprovalCard(sessionId: sessionId)),
              ),
              const SizedBox(height: 6),
              CodeComposer(
                key: ValueKey('board.inspector.composer.$sessionId'),
                sessionId: sessionId,
                prefill: state.composerPrefill,
                slashHost: codeSlashHost(context, ref, sessionId, busy: busy),
                busy: busy,
                mode: state.mode,
                onModeChanged: controller.setMode,
                onSend: (text, files) => controller.sendTyped(text, files: files),
                onSteer: (text, files) => controller.steer(text, files: files),
                onStop: controller.stop,
                // Esc closes the inspector (the Board's own key) unless the composer has an aside to close first. A typed
                // draft isn't lost: the Board keeps it and puts it back when the session is inspected again.
                onEscape: () {
                  final asides = ref.read(provider).asides;
                  if (asides.isEmpty) {
                    onClose();
                    return true;
                  }
                  controller.dismissAside(asides.last.id);
                  return true;
                },
                queued: [for (final q in state.queued) q.text],
                onUnqueue: controller.unqueue,
                onSendQueuedNow: controller.sendQueuedNow,
                placeholder: t.openQuestion != null ? 'Answer above, or reply in your own words' : 'Reply to the agent',
                autofocus: false,
                takeFocus: focusComposer,
                initialDraft: draft,
                onDraftChanged: onDraftChanged,
                model: model,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The inspector's left edge: drag to resize, double-click for the default width.
class InspectorEdge extends StatefulWidget {
  const InspectorEdge({super.key, required this.onDrag, required this.onEnd, required this.onReset});

  final ValueChanged<double> onDrag;
  final VoidCallback onEnd;
  final VoidCallback onReset;

  @override
  State<InspectorEdge> createState() => _InspectorEdgeState();
}

class _InspectorEdgeState extends State<InspectorEdge> {
  var _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) => widget.onDrag(d.delta.dx),
        onHorizontalDragEnd: (_) => widget.onEnd(),
        onHorizontalDragCancel: widget.onEnd,
        onDoubleTap: widget.onReset,
        child: SizedBox(
          width: 9,
          child: Center(
            child: Container(width: _hover ? 2 : 1, color: _hover ? theme.accent.withValues(alpha: 0.6) : theme.border),
          ),
        ),
      ),
    );
  }
}
