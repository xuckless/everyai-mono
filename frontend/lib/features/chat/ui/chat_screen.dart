import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/net/api_error.dart';

import '../../../app/router.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/adaptive_page.dart';
import '../../../core/ui/every_icons.dart';
import '../../../core/ui/selection.dart';
import '../chat_providers.dart';
import '../domain/chat_session.dart';
import 'composer.dart';
import 'message_view.dart';

/// Readable line length for the transcript and composer on wide windows.
const _maxContentWidth = 820.0;

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.conversationId});

  final String conversationId;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  // Keeps the composer (draft, focus) alive as it moves from the centered home
  // layout to the bottom of the transcript after the first message.
  final _composer = GlobalKey<ComposerState>();

  @override
  Widget build(BuildContext context) {
    final provider = chatSessionProvider(widget.conversationId);
    final controller = ref.read(provider.notifier);
    final model = ref.watch(provider.select((s) => s.model));
    final mode = ref.watch(provider.select((s) => s.mode));
    final phase = ref.watch(provider.select((s) => s.phase));
    final title = ref.watch(provider.select((s) => s.title));
    final isEmpty = ref.watch(provider.select((s) => s.isEmpty));
    final home = isEmpty && phase is! Loading;

    final composer = Composer(
      key: _composer,
      busy: phase.busy,
      model: model,
      mode: mode,
      minLines: home ? 2 : 1,
      placeholder: home ? 'How can I help you today?' : 'Reply to ${model.name}…',
      onSend: controller.send,
      onStop: controller.cancel,
      onModelChanged: controller.selectModel,
      onModeChanged: controller.setMode,
      toolsEnabled: ref.watch(provider.select((s) => s.toolsEnabled)),
      onToolsChanged: controller.setToolsEnabled,
    );

    return AdaptivePage(
      title: home ? '' : (title ?? 'New chat'),
      actions: [
        if (!home)
          AdaptiveIconButton(icon: EveryIcon.newChat, tooltip: 'New chat', onPressed: () => context.go(Routes.newChat)),
      ],
      body: switch (phase) {
        Loading() => const Center(child: AdaptiveProgress()),
        _ when home => _Home(composer: composer, onStarter: (text) => _composer.currentState?.prefill(text)),
        _ => Column(
          children: [
            Expanded(child: _Transcript(conversationId: widget.conversationId)),
            if (phase case Failed(:final error))
              _ErrorBanner(
                message: error.message,
                retryable: error.retryable,
                onRetry: controller.retry,
                onTopUp: error is HttpStatusError && error.outOfCredits ? () => context.go(Routes.billing) : null,
              ),
            SafeArea(
              top: false,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: _maxContentWidth),
                  child: Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 14), child: composer),
                ),
              ),
            ),
          ],
        ),
      },
    );
  }
}

/// New-chat landing: greeting, a large centered composer and starter prompts.
class _Home extends StatelessWidget {
  const _Home({required this.composer, required this.onStarter});

  final Widget composer;
  final ValueChanged<String> onStarter;

  static const _starters = <(EveryIcon, String, String)>[
    (EveryIcon.edit, 'Write', 'Help me write '),
    (EveryIcon.spark, 'Learn', 'Explain like I\'m new to it: '),
    (EveryIcon.chat, 'Code', 'Write code that '),
    (EveryIcon.globe, 'Research', 'Find the latest on '),
    (EveryIcon.copy, 'Summarize', 'Summarize this: '),
  ];

  static String _greeting(DateTime now) => switch (now.hour) {
    < 5 => 'Up late?',
    < 12 => 'Good morning',
    < 17 => 'Good afternoon',
    _ => 'Good evening',
  };

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 48),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AdaptiveIcon(EveryIcon.spark, size: 28, color: theme.accent),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      _greeting(DateTime.now()),
                      style: TextStyle(
                        color: theme.text,
                        fontSize: 34,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.6,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 28),
              composer,
              const SizedBox(height: 16),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (icon, label, prompt) in _starters)
                    _StarterChip(icon: icon, label: label, onTap: () => onStarter(prompt)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StarterChip extends StatefulWidget {
  const _StarterChip({required this.icon, required this.label, required this.onTap});

  final EveryIcon icon;
  final String label;
  final VoidCallback onTap;

  @override
  State<_StarterChip> createState() => _StarterChipState();
}

class _StarterChipState extends State<_StarterChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Semantics(
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: _hover ? theme.surfaceRaised : null,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: theme.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AdaptiveIcon(widget.icon, size: 14, color: theme.textMuted),
                const SizedBox(width: 6),
                Text(widget.label, style: TextStyle(color: theme.text, fontSize: 13)),
              ],
            ),
          ),
        ),
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
                child: MessageView(message: message, conversationId: conversationId, isLatest: i == 0),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.retryable, required this.onRetry, this.onTopUp});

  final String message;
  final bool retryable;
  final VoidCallback onRetry;

  /// Out of credits: opens Plan & usage.
  final VoidCallback? onTopUp;

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
                  if (onTopUp != null)
                    AdaptiveButton(label: 'Top up', emphasis: ButtonEmphasis.primary, onPressed: onTopUp),
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
