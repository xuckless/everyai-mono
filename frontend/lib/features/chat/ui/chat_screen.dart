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
import '../../models/ui/model_avatar.dart';
import '../chat_providers.dart';
import '../domain/chat_session.dart';
import 'composer.dart';
import 'message_view.dart';

/// Readable line length for the transcript and composer on wide windows.
const _maxContentWidth = 820.0;

class ChatScreen extends ConsumerWidget {
  const ChatScreen({super.key, required this.conversationId});

  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = chatSessionProvider(conversationId);
    final controller = ref.read(provider.notifier);
    final model = ref.watch(provider.select((s) => s.model));
    final phase = ref.watch(provider.select((s) => s.phase));
    final title = ref.watch(provider.select((s) => s.title));
    final isEmpty = ref.watch(provider.select((s) => s.isEmpty));

    return AdaptivePage(
      title: title ?? 'New chat',
      titleWidget: _ModelPicker(selected: model, enabled: !phase.busy, onSelected: controller.selectModel),
      actions: [
        AdaptiveIconButton(icon: EveryIcon.newChat, tooltip: 'New chat', onPressed: () => context.go(Routes.newChat)),
      ],
      body: Column(
        children: [
          Expanded(
            child: switch (phase) {
              Loading() => const Center(child: AdaptiveProgress()),
              _ when isEmpty => _EmptyChat(model: model),
              _ => _Transcript(conversationId: conversationId),
            },
          ),
          if (phase case Failed(:final error))
            _ErrorBanner(message: error.message, retryable: error.retryable, onRetry: controller.retry),
          SafeArea(
            top: false,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _maxContentWidth),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  child: Composer(
                    busy: phase.busy,
                    placeholder: 'Message ${model.name}  ·  @ to switch model',
                    onSend: controller.send,
                    onStop: controller.cancel,
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

class _Transcript extends ConsumerWidget {
  const _Transcript({required this.conversationId});

  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Only rebuilds when a message is added or finishes, not per streamed token.
    final messages = ref.watch(chatSessionProvider(conversationId).select((s) => s.messages));
    return AdaptiveSelectionArea(
      child: ListView.builder(
        reverse: true,
        padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top + 16, bottom: 16),
        itemCount: messages.length,
        // Newest first with reverse:true keeps the latest turn pinned to the bottom.
        itemBuilder: (context, i) {
          final message = messages[messages.length - 1 - i];
          return Center(
            key: ValueKey(message.id),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _maxContentWidth),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                child: MessageView(message: message, conversationId: conversationId),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ModelPicker extends ConsumerWidget {
  const _ModelPicker({required this.selected, required this.enabled, required this.onSelected});

  final ModelSpec selected;
  final bool enabled;
  final ValueChanged<ModelSpec> onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final library = ref.watch(libraryProvider).value ?? const [];
    final options = {...library, selected}.toList();
    final label = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ModelAvatar(selected.provider, size: 22),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            selected.name,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: theme.text, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(width: 4),
        AdaptiveIcon(EveryIcon.chevronDown, size: 14, color: theme.textMuted),
      ],
    );
    if (!enabled) return Opacity(opacity: 0.6, child: label);
    return AdaptiveMenuButton(
      tooltip: 'Choose model',
      actions: [
        for (final spec in options)
          MenuAction(label: spec.name, checked: spec == selected, onSelected: () => onSelected(spec)),
        MenuAction(label: 'All models…', icon: EveryIcon.models, onSelected: () => context.go(Routes.models)),
      ],
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), child: label),
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat({required this.model});

  final ModelSpec model;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ModelAvatar(model.provider, size: 56),
            const SizedBox(height: 16),
            Text(
              'What can I help with?',
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.text, fontSize: 24, fontWeight: FontWeight.w700, letterSpacing: -0.3),
            ),
            const SizedBox(height: 8),
            Text(
              'Chatting with ${model.name}. Type @ to ask a different model for one message.',
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.textMuted, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.retryable, required this.onRetry});

  final String message;
  final bool retryable;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _maxContentWidth),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Semantics(
            liveRegion: true,
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
              decoration: BoxDecoration(
                color: theme.danger.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(theme.radius),
                border: Border.all(color: theme.danger.withValues(alpha: 0.35)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(message, style: TextStyle(color: theme.text, fontSize: 13)),
                  ),
                  if (retryable)
                    AdaptiveButton(
                      label: 'Retry',
                      emphasis: ButtonEmphasis.plain,
                      icon: AdaptiveIcon(EveryIcon.retry, size: 16, color: theme.accent),
                      onPressed: onRetry,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
