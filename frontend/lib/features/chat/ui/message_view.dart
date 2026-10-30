import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../../models/models_providers.dart';
import '../../models/ui/model_avatar.dart';
import '../chat_providers.dart';
import '../domain/message.dart';
import 'chat_markdown.dart';

/// One message. User turns are right-aligned bubbles; assistant turns are
/// full-width documents (markdown, code, math, images) with a model header.
class MessageView extends StatelessWidget {
  const MessageView({super.key, required this.message, required this.conversationId});

  final Message message;
  final String conversationId;

  @override
  Widget build(BuildContext context) =>
      message.isUser ? _UserBubble(message) : _AssistantMessage(message: message, conversationId: conversationId);
}

class _UserBubble extends StatelessWidget {
  const _UserBubble(this.message);

  final Message message;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
        child: DecoratedBox(
          decoration: BoxDecoration(color: theme.userBubble, borderRadius: BorderRadius.circular(theme.bubbleRadius)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            // Hug short messages instead of stretching to the max bubble width.
            child: IntrinsicWidth(child: ChatMarkdown(message.plainText, textColor: theme.onUserBubble)),
          ),
        ),
      ),
    );
  }
}

class _AssistantMessage extends ConsumerWidget {
  const _AssistantMessage({required this.message, required this.conversationId});

  final Message message;
  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final spec = message.model == null ? null : ref.watch(modelCatalogProvider)[message.model!];
    final inFlight = message.status == MessageStatus.streaming;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (spec != null) ModelAvatar(spec.provider, size: 22),
            const SizedBox(width: 8),
            Text(
              spec?.name ?? message.model?.value ?? 'Assistant',
              style: TextStyle(color: theme.textMuted, fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (inFlight)
          _StreamingBody(conversationId: conversationId)
        else ...[
          for (final part in message.parts) _PartView(part),
          if (message.status == MessageStatus.cancelled)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Stopped',
                style: TextStyle(color: theme.textMuted, fontSize: 12, fontStyle: FontStyle.italic),
              ),
            ),
          if (message.status == MessageStatus.failed && message.error != null)
            Text(message.error!, style: TextStyle(color: theme.danger, fontSize: 13)),
          if (message.plainText.isNotEmpty) _MessageActions(message),
        ],
      ],
    );
  }
}

/// Rebuilds on every token. Only this widget watches `streamingText`, so the
/// rest of the transcript stays put while a response streams in.
class _StreamingBody extends ConsumerWidget {
  const _StreamingBody({required this.conversationId});

  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = ref.watch(chatSessionProvider(conversationId).select((s) => s.streamingText));
    if (text.isEmpty) return const _TypingIndicator();
    return ChatMarkdown(text, streaming: true);
  }
}

class _PartView extends StatelessWidget {
  const _PartView(this.part);

  final MessagePart part;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return switch (part) {
      TextPart(:final text) => ChatMarkdown(text),
      ImagePart(:final bytes?) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(theme.radius),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 512, maxHeight: 512),
            child: Image.memory(bytes, fit: BoxFit.contain, semanticLabel: 'Generated image'),
          ),
        ),
      ),
      ImagePart() => Text('[Image unavailable]', style: TextStyle(color: theme.textMuted)),
      ToolCallPart(:final toolName) => Text('Used $toolName', style: TextStyle(color: theme.textMuted, fontSize: 13)),
      ArtifactPart(:final title) => Text(title, style: TextStyle(color: theme.accent)),
    };
  }
}

class _MessageActions extends StatelessWidget {
  const _MessageActions(this.message);

  final Message message;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          AdaptiveIconButton(
            icon: EveryIcon.copy,
            tooltip: 'Copy',
            size: 16,
            color: theme.textMuted,
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: message.plainText));
              if (context.mounted) showAdaptiveToast(context, 'Copied');
            },
          ),
        ],
      ),
    );
  }
}

class _TypingIndicator extends StatefulWidget {
  const _TypingIndicator();

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    if (MediaQuery.disableAnimationsOf(context)) {
      return Text('Thinking…', style: TextStyle(color: theme.textMuted));
    }
    return Semantics(
      label: 'Waiting for response',
      child: SizedBox(
        height: 20,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < 3; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 5),
                  child: Opacity(
                    opacity: 0.3 + 0.7 * _pulse((_controller.value - i * 0.18) % 1.0),
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(color: theme.textMuted, shape: BoxShape.circle),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static double _pulse(double t) => t < 0.5 ? t * 2 : (1 - t) * 2;
}
