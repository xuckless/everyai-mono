import '../../../core/ui/brand.dart';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/platform/platform_kind.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/anchored_popover.dart';
import '../../../core/ui/every_icons.dart';
import '../../artifacts/ui/visual_view.dart';
import '../../attachments/attachment.dart';
import '../../attachments/ui/attachment_tray.dart';
import '../../models/models_providers.dart';
import '../../models/ui/model_avatar.dart';
import '../chat_providers.dart';
import '../domain/message.dart';
import 'chat_markdown.dart';
import 'tool_steps.dart';

/// One message. User turns are right-aligned bubbles with edit and copy on
/// hover; assistant turns are full-width documents with sources, follow-ups and
/// an action bar (copy, retry, retry with another model).
class MessageView extends StatelessWidget {
  const MessageView({super.key, required this.message, required this.conversationId, required this.isLatest});

  final Message message;
  final String conversationId;

  /// The newest answer keeps its actions visible and offers retry.
  final bool isLatest;

  @override
  Widget build(BuildContext context) => message.isUser
      ? _UserMessage(message: message, conversationId: conversationId)
      : _AssistantMessage(message: message, conversationId: conversationId, isLatest: isLatest);
}

/// Shows actions while the pointer is over the message; always on touch devices.
class _HoverActions extends StatefulWidget {
  const _HoverActions({required this.builder, this.alwaysVisible = false});

  final Widget Function(BuildContext context, bool showActions) builder;
  final bool alwaysVisible;

  @override
  State<_HoverActions> createState() => _HoverActionsState();
}

class _HoverActionsState extends State<_HoverActions> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: widget.builder(context, widget.alwaysVisible || _hover || Host.isMobile),
  );
}

class _Reveal extends StatelessWidget {
  const _Reveal({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
    opacity: visible ? 1 : 0,
    duration: const Duration(milliseconds: 120),
    child: IgnorePointer(ignoring: !visible, child: child),
  );
}

class _UserMessage extends ConsumerStatefulWidget {
  const _UserMessage({required this.message, required this.conversationId});

  final Message message;
  final String conversationId;

  @override
  ConsumerState<_UserMessage> createState() => _UserMessageState();
}

class _UserMessageState extends ConsumerState<_UserMessage> {
  TextEditingController? _editing;

  void _startEdit() => setState(() => _editing = TextEditingController(text: widget.message.plainText));

  void _cancelEdit() {
    _editing?.dispose();
    setState(() => _editing = null);
  }

  void _submitEdit() {
    final text = _editing!.text;
    _cancelEdit();
    ref.read(chatSessionProvider(widget.conversationId).notifier).editAndResend(widget.message.id, text);
  }

  @override
  void dispose() {
    _editing?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final busy = ref.watch(chatSessionProvider(widget.conversationId).select((s) => s.phase.busy));

    if (_editing case final controller?) {
      return Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        decoration: BoxDecoration(
          color: theme.surfaceRaised,
          borderRadius: theme.userBubbleShape,
          border: Border.all(color: theme.accent.withValues(alpha: 0.6)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AdaptiveTextField(controller: controller, minLines: 1, maxLines: 12, borderless: true, autofocus: true),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                AdaptiveButton(label: 'Cancel', emphasis: ButtonEmphasis.plain, onPressed: _cancelEdit),
                const SizedBox(width: 8),
                AdaptiveButton(label: 'Send', onPressed: busy ? null : _submitEdit),
              ],
            ),
          ],
        ),
      );
    }

    // Loose width from the centered transcript column would shrink this to
    // the bubble and center it; fill the width so the bubble sits right.
    return Align(
      alignment: Alignment.centerRight,
      child: _HoverActions(
        builder: (context, show) => Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (widget.message.attachments case final files when files.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [for (final a in files) _SentAttachment(a)],
                ),
              ),
            if (widget.message.plainText.isNotEmpty)
              LayoutBuilder(
                builder: (context, constraints) => ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.8),
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: theme.userBubble, borderRadius: theme.userBubbleShape),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      // Hug short messages instead of stretching to the max width.
                      child: IntrinsicWidth(
                        child: ChatMarkdown(widget.message.plainText, textColor: theme.onUserBubble),
                      ),
                    ),
                  ),
                ),
              ),
            _Reveal(
              visible: show,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ActionIcon(icon: EveryIcon.edit, tooltip: 'Edit message', onPressed: busy ? null : _startEdit),
                  _CopyAction(text: widget.message.plainText),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// An attachment in a sent message: images as a thumbnail, other files as a chip.
class _SentAttachment extends StatelessWidget {
  const _SentAttachment(this.part);

  final AttachmentPart part;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    if (part.kind == AttachmentKind.image && part.bytes != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(theme.radius),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240, maxHeight: 240),
          child: Image.memory(part.bytes!, fit: BoxFit.cover, semanticLabel: part.name),
        ),
      );
    }
    return AttachmentChip(name: part.name, kind: part.kind, size: part.size);
  }
}

class _AssistantMessage extends ConsumerWidget {
  const _AssistantMessage({required this.message, required this.conversationId, required this.isLatest});

  final Message message;
  final String conversationId;
  final bool isLatest;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final spec = message.model == null ? null : ref.watch(modelCatalogProvider)[message.model!];
    final inFlight = message.status == MessageStatus.streaming;

    final body = <Widget>[
      if (inFlight)
        _LiveBody(conversationId: conversationId)
      else ...[
        for (final part in message.parts)
          _PartView(part: part, sources: message.sources, conversationId: conversationId, isLatest: isLatest),
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
      ],
    ];

    return _HoverActions(
      alwaysVisible: isLatest,
      builder: (context, show) => Column(
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
          const SizedBox(height: 8),
          ...body,
          if (!inFlight)
            _Reveal(
              visible: show,
              child: _AssistantActions(message: message, conversationId: conversationId, isLatest: isLatest),
            ),
        ],
      ),
    );
  }
}

/// Rebuilds per token. Only this widget watches `streamingText` and `liveSources`.
class _LiveBody extends ConsumerWidget {
  const _LiveBody({required this.conversationId});

  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = chatSessionProvider(conversationId);
    final text = ref.watch(provider.select((s) => s.streamingText));
    final sources = ref.watch(provider.select((s) => s.liveSources));
    final parts = ref.watch(provider.select((s) => s.liveParts));
    final reasoning = ref.watch(provider.select((s) => s.streamingReasoning));
    final tools = ref.watch(provider.select((s) => s.liveTools));
    final toolRunning = tools.any((t) => t.running);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (reasoning.isNotEmpty) _Reasoning(reasoning, live: text.isEmpty && parts.isEmpty),
        if (sources.isNotEmpty) _SourcesRow(sources),
        for (final part in parts)
          _PartView(part: part, sources: sources, conversationId: conversationId, isLatest: false),
        if (tools.isNotEmpty) LiveToolSteps(steps: tools),
        if (text.isNotEmpty)
          ChatMarkdown(text, streaming: true, sources: sources)
        else if (!toolRunning && reasoning.isEmpty)
          const _TypingIndicator(),
      ],
    );
  }
}

class _AssistantActions extends ConsumerWidget {
  const _AssistantActions({required this.message, required this.conversationId, required this.isLatest});

  final Message message;
  final String conversationId;
  final bool isLatest;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final controller = ref.read(chatSessionProvider(conversationId).notifier);
    final busy = ref.watch(chatSessionProvider(conversationId).select((s) => s.phase.busy));
    final library = ref.watch(libraryProvider).value ?? const [];
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          if (message.plainText.isNotEmpty) _CopyAction(text: message.plainText),
          if (isLatest) ...[
            _ActionIcon(icon: EveryIcon.retry, tooltip: 'Retry', onPressed: busy ? null : controller.regenerate),
            if (!busy)
              AnchoredPopover(
                width: 260,
                builder: (context, close) => SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const PopoverHeader('Retry with'),
                      for (final spec in library)
                        PopoverRow(
                          leading: ModelAvatar(spec.provider, size: 18),
                          title: spec.name,
                          onTap: () {
                            close();
                            controller.regenerate(model: spec);
                          },
                        ),
                    ],
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Retry with', style: TextStyle(color: theme.textMuted, fontSize: 12.5)),
                      const SizedBox(width: 2),
                      AdaptiveIcon(EveryIcon.chevronDown, size: 11, color: theme.textMuted),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _ActionIcon extends StatelessWidget {
  const _ActionIcon({required this.icon, required this.tooltip, required this.onPressed});

  final EveryIcon icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => AdaptiveIconButton(
    icon: icon,
    tooltip: tooltip,
    size: 15,
    color: EveryTheme.of(context).textMuted,
    onPressed: onPressed,
  );
}

class _CopyAction extends StatefulWidget {
  const _CopyAction({required this.text});

  final String text;

  @override
  State<_CopyAction> createState() => _CopyActionState();
}

class _CopyActionState extends State<_CopyAction> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) => _ActionIcon(
    icon: _copied ? EveryIcon.check : EveryIcon.copy,
    tooltip: _copied ? 'Copied' : 'Copy',
    onPressed: () async {
      await Clipboard.setData(ClipboardData(text: widget.text));
      if (!mounted) return;
      setState(() => _copied = true);
      await Future<void>.delayed(const Duration(seconds: 2));
      if (mounted) setState(() => _copied = false);
    },
  );
}

/// "N sources" and a horizontal row of source cards (search modes).
class _SourcesRow extends StatelessWidget {
  const _SourcesRow(this.sources);

  final List<Source> sources;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${sources.length} source${sources.length == 1 ? '' : 's'}',
            style: TextStyle(color: theme.textMuted, fontSize: 12.5, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 78,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: sources.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) => _SourceCard(index: i + 1, source: sources[i]),
            ),
          ),
        ],
      ),
    );
  }
}

class _SourceCard extends StatefulWidget {
  const _SourceCard({required this.index, required this.source});

  final int index;
  final Source source;

  @override
  State<_SourceCard> createState() => _SourceCardState();
}

class _SourceCardState extends State<_SourceCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final s = widget.source;
    return Semantics(
      link: true,
      label: 'Source ${widget.index}: ${s.title}, ${s.site}',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: () => launchUrl(s.url, mode: LaunchMode.externalApplication),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 184,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _hover ? theme.surfaceRaised : theme.surface,
              borderRadius: BorderRadius.circular(theme.radius),
              border: Border.all(color: theme.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    s.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: theme.text, fontSize: 12.5, height: 1.3, fontWeight: FontWeight.w500),
                  ),
                ),
                Row(
                  children: [
                    SiteBadge(site: s.site),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${s.site} · ${widget.index}',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: theme.textMuted, fontSize: 11.5),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Letter badge standing in for a favicon (no network fetch per source).
class SiteBadge extends StatelessWidget {
  const SiteBadge({super.key, required this.site, this.size = 16});

  final String site;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final hue = (site.hashCode % 360).toDouble();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: HSLColor.fromAHSL(1, hue, 0.45, theme.isDark ? 0.38 : 0.52).toColor(),
        borderRadius: BorderRadius.circular(size / 4),
      ),
      child: Text(
        site.isEmpty ? '?' : site[0].toUpperCase(),
        style: TextStyle(color: const Color(0xFFFFFFFF), fontSize: size * 0.62, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _FollowUps extends ConsumerWidget {
  const _FollowUps({required this.questions, required this.conversationId});

  final List<String> questions;
  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final controller = ref.read(chatSessionProvider(conversationId).notifier);
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Related',
            style: TextStyle(color: theme.text, fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          for (final q in questions) ...[
            Container(height: 1, color: theme.border),
            PopoverRow(
              title: q,
              trailing: AdaptiveIcon(EveryIcon.add, size: 14, color: theme.accent),
              onTap: () => controller.send(q),
            ),
          ],
        ],
      ),
    );
  }
}

/// Waiting for the first token: the mark's arms fade in turn.
class _TypingIndicator extends StatelessWidget {
  const _TypingIndicator();

  @override
  Widget build(BuildContext context) => const SizedBox(
    height: 22,
    child: Align(alignment: Alignment.centerLeft, child: EveryMarkActivity(size: 18)),
  );
}

/// One finished part of an assistant message.
class _PartView extends StatelessWidget {
  const _PartView({required this.part, required this.sources, required this.conversationId, required this.isLatest});

  final MessagePart part;
  final List<Source> sources;
  final String conversationId;
  final bool isLatest;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return switch (part) {
      SourcesPart(:final sources) => _SourcesRow(sources),
      TextPart(:final text) => ChatMarkdown(text, sources: sources),
      ReasoningPart(:final text) => _Reasoning(text),
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
      FollowUpsPart(:final questions) =>
        isLatest ? _FollowUps(questions: questions, conversationId: conversationId) : const SizedBox.shrink(),
      final ToolCallPart call => InlineVisual(part: call, conversationId: conversationId),
      ArtifactPart(:final title) => Text(title, style: TextStyle(color: theme.accent)),
      UsagePart() || AttachmentPart() => const SizedBox.shrink(),
    };
  }
}

/// The model's thinking: one line while it streams, expandable afterwards.
class _Reasoning extends StatefulWidget {
  const _Reasoning(this.text, {this.live = false});

  final String text;
  final bool live;

  @override
  State<_Reasoning> createState() => _ReasoningState();
}

class _ReasoningState extends State<_Reasoning> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final muted = TextStyle(color: theme.textMuted, fontSize: 13);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () => setState(() => _open = !_open),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.live ? 'Thinking…' : 'Thought process',
                    style: muted.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(width: 4),
                  AnimatedRotation(
                    turns: _open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: AdaptiveIcon(EveryIcon.chevronDown, size: 12, color: theme.textMuted),
                  ),
                ],
              ),
            ),
          ),
          if (_open)
            Container(
              margin: const EdgeInsets.only(top: 6),
              padding: const EdgeInsets.only(left: 10),
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: theme.border, width: 2)),
              ),
              child: Text(widget.text, style: muted),
            )
          else if (widget.live)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                widget.text.split('\n').lastWhere((l) => l.trim().isNotEmpty, orElse: () => ''),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: muted,
              ),
            ),
        ],
      ),
    );
  }
}
