import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/platform_kind.dart';
import '../../../core/motion/motion.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/anchored_popover.dart';
import '../../../core/ui/every_icons.dart';
import '../../artifacts/checks/look.dart' show lookTool;
import '../../artifacts/ui/look_row.dart';
import '../../artifacts/ui/image_view.dart';
import '../../artifacts/ui/visual_view.dart';
import '../../attachments/attachment.dart';
import '../../attachments/ui/attachment_tray.dart';
import '../../attachments/ui/image_viewer.dart';
import '../../memory/memory_providers.dart';
import '../../memory/ui/local_tool_chip.dart';
import '../../models/domain/model_catalog.dart';
import '../../models/models_providers.dart';
import '../../models/ui/model_avatar.dart';
import '../chat_providers.dart';
import '../domain/ask_user.dart';
import '../domain/message.dart';
import '../domain/security_alert.dart';
import '../domain/suggest_mode.dart';
import 'ask_user_card.dart';
import 'chat_markdown.dart';
import 'link_gate.dart';
import 'security_alert_card.dart';
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
      return MouseRegion(
        cursor: SystemMouseCursors.zoomIn,
        child: GestureDetector(
          onTap: () => showImageViewer(context, part.bytes!, label: part.name),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(theme.radius),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240, maxHeight: 240),
              child: Image.memory(part.bytes!, fit: BoxFit.cover, semanticLabel: part.name),
            ),
          ),
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
    final route = inFlight
        ? ref.watch(chatSessionProvider(conversationId).select((s) => s.liveParts.whereType<RoutePart>().firstOrNull))
        : message.route;

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
              style: theme.type.caption.tint(theme.textMuted).copyWith(fontStyle: FontStyle.italic),
            ),
          ),
        if (message.status == MessageStatus.failed && message.error != null)
          Text(message.error!, style: theme.type.callout.tint(theme.danger)),
      ],
    ];

    return _HoverActions(
      alwaysVisible: isLatest,
      builder: (context, show) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ...body,
          if (!inFlight)
            _Reveal(
              visible: show,
              child: _AssistantActions(
                message: message,
                conversationId: conversationId,
                isLatest: isLatest,
                answeredBy: route != null
                    ? _RouteChip(route: route, conversationId: conversationId, offerRerun: isLatest)
                    : Text(
                        spec?.name ?? message.model?.value ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.type.caption.tint(theme.textSubtle),
                      ),
              ),
            ).settle(delay: const Duration(milliseconds: 90))
          else if (route != null)
            _RouteChip(route: route, conversationId: conversationId, offerRerun: false),
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
  const _AssistantActions({
    required this.message,
    required this.conversationId,
    required this.isLatest,
    required this.answeredBy,
  });

  final Message message;
  final String conversationId;
  final bool isLatest;

  /// Who answered (the model's name, or the Auto route chip), at the row's end.
  final Widget answeredBy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(chatSessionProvider(conversationId).notifier);
    final busy = ref.watch(chatSessionProvider(conversationId).select((s) => s.phase.busy));
    final library = ref.watch(libraryProvider).value ?? const [];
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Transform.translate(
        offset: const Offset(-8, 0),
        child: Row(
          children: [
            if (message.plainText.isNotEmpty) _CopyAction(text: message.plainText),
            if (isLatest) ...[
              _ActionIcon(icon: EveryIcon.retry, tooltip: 'Retry', onPressed: busy ? null : controller.regenerate),
              if (!busy)
                AnchoredPopover(
                  width: 240,
                  builder: (context, close) => SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const PopoverHeader('Retry with'),
                        for (final (i, spec) in library.indexed)
                          PopoverRow(
                            leading: ModelAvatar(spec.provider, size: 18),
                            title: spec.name,
                            onTap: () {
                              close();
                              controller.regenerate(model: spec);
                            },
                          ).rowIn(i),
                      ],
                    ),
                  ),
                  child: const IgnorePointer(
                    child: KitIconButton(icon: EveryIcon.more, tooltip: 'More', onPressed: _noop),
                  ),
                ),
            ],
            const SizedBox(width: 8),
            Expanded(
              child: Align(alignment: Alignment.centerRight, child: answeredBy),
            ),
          ],
        ),
      ),
    );
  }
}

void _noop() {}

class _ActionIcon extends StatelessWidget {
  const _ActionIcon({required this.icon, required this.tooltip, required this.onPressed});

  final EveryIcon icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => KitIconButton(icon: icon, tooltip: tooltip, size: 15, onPressed: onPressed);
}

class _CopyAction extends StatefulWidget {
  const _CopyAction({required this.text});

  final String text;

  @override
  State<_CopyAction> createState() => _CopyActionState();
}

class _CopyActionState extends State<_CopyAction> {
  bool _copied = false;
  int _pulse = 0;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return SuccessPulse(
      trigger: _pulse == 0 ? null : _pulse,
      color: theme.success,
      radius: 9,
      spread: 8,
      child: KitIconButton(
        icon: EveryIcon.copy,
        tooltip: _copied ? 'Copied' : 'Copy',
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: widget.text));
          if (!mounted) return;
          setState(() {
            _copied = true;
            _pulse++;
          });
          await Future<void>.delayed(const Duration(milliseconds: 1400));
          if (mounted) setState(() => _copied = false);
        },
        child: IconSwap(
          child: _copied
              ? Icon(EveryIcon.check.data, key: const ValueKey('check'), size: 15, color: theme.success)
              : Icon(EveryIcon.copy.data, key: const ValueKey('copy'), size: 15),
        ),
      ),
    );
  }
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
            style: theme.type.callout.semibold.tint(theme.textMuted),
          ),
          const SizedBox(height: 8),
          // Out of the chat's text selection: the cards are links, and a selection drag reaching this sideways list
          // (nested in the chat's own) tripped Flutter's auto-scroll and left the whole chat unselectable.
          SelectionContainer.disabled(
            child: SizedBox(
              height: 78,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: sources.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, i) => _SourceCard(index: i + 1, source: sources[i]),
              ),
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
          onTap: () => openOutside(context, s.url),
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
                    style: theme.type.callout.medium.tint(theme.text).copyWith(height: 1.3),
                  ),
                ),
                Row(
                  children: [
                    SiteBadge(site: s.site, host: s.url.host),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${s.site} · ${widget.index}',
                        overflow: TextOverflow.ellipsis,
                        style: theme.type.caption.tint(theme.textMuted),
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

/// The site's favicon, through DuckDuckGo's icon service (the sites themselves aren't contacted, so they don't see
/// the reader). A letter badge shows while it loads and stays when there is no icon (or no [host]).
class SiteBadge extends StatelessWidget {
  const SiteBadge({super.key, required this.site, this.host, this.size = 16});

  final String site;

  /// The source's host name, for its favicon.
  final String? host;
  final double size;

  @override
  Widget build(BuildContext context) {
    final letter = _Letter(site: site, size: size);
    final h = host;
    if (h == null || h.isEmpty) return letter;
    return ClipRRect(
      borderRadius: BorderRadius.circular(size / 4),
      child: Image.network(
        faviconUrl(h),
        width: size,
        height: size,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        // Its decoded size, not the service's 32-64 px original, so dozens of cards stay light.
        cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
        frameBuilder: (context, child, frame, sync) => frame == null && !sync ? letter : child,
        errorBuilder: (context, _, _) => letter,
      ),
    );
  }
}

/// Where a host's favicon comes from (see [SiteBadge]).
@visibleForTesting
String faviconUrl(String host) => 'https://icons.duckduckgo.com/ip3/${Uri.encodeComponent(host)}.ico';

/// A letter on a colour from the site's name: the badge while the favicon loads, or when it has none.
class _Letter extends StatelessWidget {
  const _Letter({required this.site, required this.size});

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
        style: TextStyle(color: const Color(0xFFFFFFFF), fontSize: size * 0.62, fontWeight: FontWeight.w600),
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
      padding: const EdgeInsets.only(top: 14, bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, q) in questions.indexed)
            Transform.translate(
              offset: const Offset(-10, 0),
              child: MenuRow(
                leading: AdaptiveIcon(EveryIcon.arrowUpRight, size: 15, color: theme.textSubtle),
                onTap: () => controller.send(q),
                child: Text(q, style: theme.type.callout.tint(theme.textMuted)),
              ),
            ).rowIn(i),
        ],
      ),
    );
  }
}

/// The `suggest_mode` button: asks the last question again in another mode.
class _SuggestedMode extends ConsumerWidget {
  const _SuggestedMode({required this.part, required this.conversationId, required this.isLatest});

  final ToolCallPart part;
  final String conversationId;
  final bool isLatest;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (:mode, :reason) = suggestedMode(part);
    // Only the latest answer offers it, and not for the mode the chat is in.
    if (mode == null || !isLatest) return const SizedBox.shrink();
    final current = ref.watch(chatSessionProvider(conversationId).select((s) => s.mode));
    if (mode == current) return const SizedBox.shrink();
    final theme = EveryTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Align(
        alignment: Alignment.centerLeft,
        child: AdaptiveButton(
          label: 'Run as ${mode.label}${reason.isEmpty ? '' : ' · $reason'}',
          emphasis: ButtonEmphasis.secondary,
          icon: AdaptiveIcon(EveryIcon.spark, size: 14, color: theme.accent),
          onPressed: () => ref.read(chatSessionProvider(conversationId).notifier).rerunIn(mode),
        ),
      ),
    );
  }
}

/// What Auto picked: "Auto · Search · Sonnet 5.5". On the latest answer a
/// tap offers asking again in another mode, on the model Auto picked.
class _RouteChip extends ConsumerWidget {
  const _RouteChip({required this.route, required this.conversationId, required this.offerRerun});

  final RoutePart route;
  final String conversationId;
  final bool offerRerun;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final model = ref.watch(modelCatalogProvider).resolve(route.model);
    final busy = ref.watch(chatSessionProvider(conversationId).select((s) => s.phase.busy));
    final label = routeLabel(route, model);
    final interactive = offerRerun && !busy;
    final chip = Semantics(
      label: 'Auto picked ${route.mode.label} with ${model.name}',
      button: interactive,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: theme.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.type.caption.tint(theme.textMuted),
              ),
            ),
            if (interactive) ...[
              const SizedBox(width: 3),
              AdaptiveIcon(EveryIcon.chevronDown, size: 10, color: theme.textMuted),
            ],
          ],
        ),
      ),
    );
    if (!interactive) return Flexible(child: chip);
    return Flexible(
      child: AnchoredPopover(
        width: 260,
        builder: (context, close) => SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PopoverHeader('Ask again with ${model.shortName} as'),
              for (final mode in ChatMode.values)
                if (mode != route.mode)
                  PopoverRow(
                    title: mode.label,
                    subtitle: mode.description,
                    onTap: () {
                      close();
                      ref.read(chatSessionProvider(conversationId).notifier).rerunIn(mode, model: model);
                    },
                  ),
            ],
          ),
        ),
        child: MouseRegion(cursor: SystemMouseCursors.click, child: chip),
      ),
    );
  }
}

/// "Auto · Search · Sonnet 5.5" for [route], answered by [model].
String routeLabel(RoutePart route, ModelSpec model) => 'Auto · ${route.mode.label} · ${model.shortName}';

/// Waiting for the first token: the mark's arms fade in turn.
class _TypingIndicator extends StatelessWidget {
  const _TypingIndicator();

  @override
  Widget build(BuildContext context) => const SizedBox(
    height: 24,
    child: Align(alignment: Alignment.centerLeft, child: ShimmerText('Thinking')),
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
      final ImagePart image => GeneratedImageView(image: image, conversationId: conversationId),
      FollowUpsPart(:final questions) =>
        isLatest ? _FollowUps(questions: questions, conversationId: conversationId) : const SizedBox.shrink(),
      final ToolCallPart call when call.toolName == askUserTool => AskUserCard(
        part: call,
        conversationId: conversationId,
      ),
      final ToolCallPart call when call.toolName == suggestModeTool => _SuggestedMode(
        part: call,
        conversationId: conversationId,
        isLatest: isLatest,
      ),
      final ToolCallPart call when call.toolName == securityAlertTool => SecurityAlertCard(part: call),
      final ToolCallPart call when allLocalChatTools.contains(call.toolName) => LocalToolChip(part: call),
      final ToolCallPart call when call.toolName == lookTool => LookRow(part: call),
      final ToolCallPart call => InlineVisual(part: call, conversationId: conversationId),
      ArtifactPart(:final title) => Text(title, style: theme.type.body.tint(theme.accent)),
      // The route shows as a chip in the header.
      UsagePart() || AttachmentPart() || RoutePart() => const SizedBox.shrink(),
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
    final muted = theme.type.callout.tint(theme.textMuted);
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
                  Text(widget.live ? 'Thinking…' : 'Thought process', style: muted.medium),
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
