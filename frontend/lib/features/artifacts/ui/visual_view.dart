import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../../chat/chat_providers.dart';
import '../../chat/domain/message.dart';
import '../../chat/ui/chat_markdown.dart';
import '../artifact_providers.dart';
import '../domain/artifact.dart';
import '../domain/drawing.dart';
import 'download_button.dart';
import 'image_view.dart';
import 'renderers/chart_view.dart';
import 'renderers/drawing_page.dart';
import 'renderers/flashcards_view.dart';
import 'renderers/quiz_view.dart';
import 'renderers/slides_view.dart';
import 'renderers/svg_view.dart';
import 'renderers/web_view.dart';

EveryIcon iconOf(VisualKind kind) => switch (kind) {
  VisualKind.document => EveryIcon.document,
  VisualKind.code || VisualKind.html || VisualKind.widget => EveryIcon.code,
  VisualKind.svg => EveryIcon.image,
  VisualKind.diagram => EveryIcon.diagram,
  VisualKind.chart => EveryIcon.chart,
  VisualKind.quiz => EveryIcon.quiz,
  VisualKind.flashcards => EveryIcon.cards,
  VisualKind.slides => EveryIcon.slides,
  VisualKind.image => EveryIcon.image,
  VisualKind.drawing => EveryIcon.drawing,
};

/// The rendered content of a visual. [expanded] is the side panel's size.
class VisualBody extends ConsumerWidget {
  const VisualBody({super.key, required this.visual, required this.conversationId, this.expanded = false});

  final Visual visual;
  final String conversationId;
  final bool expanded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = EveryTheme.of(context).brightness == Brightness.dark;
    final content = visual.str('content');
    return switch (visual.kind) {
      VisualKind.document => ChatMarkdown(content),
      VisualKind.code => ChatMarkdown('```${visual.str('language')}\n$content\n```'),
      VisualKind.html => WebContentView(
        html: content,
        fallbackSource: content,
        height: expanded ? null : 360,
        interactive: ref.watch(webInteractiveProvider(webArtifactKey(visual))),
      ),
      VisualKind.widget => WebContentView(
        html: visual.str('html'),
        fallbackSource: visual.str('html'),
        height: null,
        surface: WebSurface.widget,
        onSend: (text) =>
            sendFromWidget(context, text, (t) => ref.read(chatSessionProvider(conversationId).notifier).send(t)),
      ),
      VisualKind.svg => SvgView(svg: visual.args['svg'] as String? ?? content, maxHeight: expanded ? 900 : 420),
      VisualKind.diagram => () {
        final source = visual.args['mermaid'] as String? ?? content;
        return WebContentView(
          html: mermaidPage(source, dark: dark),
          fallbackSource: source,
          height: expanded ? null : 340,
          surface: WebSurface.diagram,
        );
      }(),
      VisualKind.chart => ChartView(visual: visual, height: expanded ? 380 : 260),
      VisualKind.quiz => QuizView(visual: visual, conversationId: conversationId),
      VisualKind.flashcards => FlashcardsView(visual: visual, height: expanded ? 300 : 210),
      VisualKind.slides => SlidesView(visual: visual, showNotes: expanded),
      VisualKind.image => RasterImageView(bytes: visual.args['bytes'] as Uint8List?, maxHeight: expanded ? 900 : 512),
      VisualKind.drawing => WebContentView(
        html: drawingPage(scene: content, mermaid: visual.args['mermaid'] as String?, dark: dark),
        fallbackSource: content,
        height: expanded ? null : 360,
        surface: WebSurface.drawing,
        onScene: (scene) => ref.read(drawingDraftProvider(visual.callId).notifier).set(scene),
      ),
    };
  }
}

/// A widget's `everyai.send(text)`: the widget is model-written (and could
/// carry injected code), so its text goes out as the user's message only
/// after the user has read it and confirmed.
Future<void> sendFromWidget(BuildContext context, String text, void Function(String text) send) async {
  final ok = await showAdaptiveConfirm(
    context,
    title: 'Send this message?',
    message: 'The widget wants to send this as your message:\n\n$text',
    confirmLabel: 'Send',
  );
  if (ok && context.mounted) send(text);
}

/// The key of a web page's static/interactive switch: its artifact id.
String webArtifactKey(Visual v) => v.str('id').isEmpty ? v.callId : v.str('id');

/// A UI tool call in the chat: interactive inline for quizzes, flashcards,
/// charts, illustrations and diagrams; a card that opens the side panel for
/// documents, code, web pages and slides.
class InlineVisual extends ConsumerWidget {
  const InlineVisual({super.key, required this.part, required this.conversationId});

  final ToolCallPart part;
  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final call = Visual.fromPart(part);
    if (call == null) {
      return Text('Used ${part.toolName}', style: TextStyle(color: theme.textMuted, fontSize: 13));
    }
    final panel = ref.read(artifactPanelProvider(conversationId).notifier);
    final isArtifact = artifactTools.contains(part.toolName);
    // An artifact call shows the version it made (an edit only carries its
    // find-and-replace pairs).
    final made = !isArtifact
        ? null
        : ref
              .watch(conversationArtifactsProvider(conversationId))
              .expand((a) => a.versions)
              .where((v) => v.callId == call.callId)
              .firstOrNull;
    if (part.toolName == 'edit_artifact' && made == null) {
      return Text(
        'Edited an artifact that is not in this chat',
        style: TextStyle(color: theme.textMuted, fontSize: 13),
      );
    }
    final visual = made ?? call;
    // A widget is part of the answer: drawn in the message, without a card.
    if (visual.kind == VisualKind.widget) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        constraints: const BoxConstraints(maxWidth: 680),
        child: VisualBody(visual: visual, conversationId: conversationId),
      );
    }
    final missed = (visual.args['edit_missed'] as List?)?.length ?? 0;
    void open() {
      if (isArtifact) {
        final id = visual.str('id').isEmpty ? visual.callId : visual.str('id');
        final artifacts = ref.read(conversationArtifactsProvider(conversationId));
        final artifact = artifacts.where((a) => a.id == id).firstOrNull;
        final version = artifact?.versions.indexWhere((v) => v.callId == visual.callId);
        panel.openArtifact(id, version: version == null || version < 0 ? null : version);
      } else {
        panel.openVisual(visual);
      }
    }

    final subtitle = [
      switch (part.toolName) {
        _ when call.args['edited_by'] == 'user' => 'Edited by you',
        'update_artifact' => 'Updated ${visual.kind.label.toLowerCase()}',
        'edit_artifact' => 'Edited ${visual.kind.label.toLowerCase()}',
        _ => visual.kind.label,
      },
      if (missed > 0) '$missed edit${missed == 1 ? '' : 's'} did not apply',
      switch (visual.kind) {
        VisualKind.quiz => '${(visual.args['questions'] as List?)?.length ?? 0} questions',
        VisualKind.flashcards => '${(visual.args['cards'] as List?)?.length ?? 0} cards',
        VisualKind.slides => '${slidesOf(visual).length} slides',
        VisualKind.drawing => switch (drawingElementCount(visual.str('content'))) {
          0 => null,
          1 => '1 element',
          final n => '$n elements',
        },
        VisualKind.code when visual.str('language').isNotEmpty => visual.str('language'),
        _ => null,
      },
    ].nonNulls.join(' · ');

    final header = Row(
      children: [
        Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: theme.accent.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(8),
          ),
          child: AdaptiveIcon(iconOf(visual.kind), size: 17, color: theme.accent),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                visual.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: theme.text, fontWeight: FontWeight.w600, fontSize: 14),
              ),
              Text(subtitle, style: TextStyle(color: theme.textMuted, fontSize: 12)),
            ],
          ),
        ),
        if (!kIsWeb) DownloadButton(visual: visual),
        AdaptiveIconButton(icon: EveryIcon.openPanel, tooltip: 'Open in side panel', onPressed: open),
      ],
    );

    final card = Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      constraints: const BoxConstraints(maxWidth: 680),
      decoration: BoxDecoration(
        color: theme.surfaceRaised,
        borderRadius: BorderRadius.circular(EveryTheme.cardRadius),
        border: Border.all(color: theme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          if (!visual.kind.opensInPanel) ...[
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: VisualBody(visual: visual, conversationId: conversationId),
            ),
          ] else if (visual.kind == VisualKind.slides) ...[
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(theme.radius),
                  child: SlideCanvas(
                    slide: slidesOf(visual).first,
                    theme: DeckTheme.of(visual.str('theme')),
                    isTitle: true,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
    if (!visual.kind.opensInPanel) return card;
    return GestureDetector(
      onTap: open,
      child: MouseRegion(cursor: SystemMouseCursors.click, child: card),
    );
  }
}
