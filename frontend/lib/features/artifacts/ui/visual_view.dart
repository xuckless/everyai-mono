import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../../chat/domain/message.dart';
import '../../chat/ui/chat_markdown.dart';
import '../artifact_providers.dart';
import '../domain/artifact.dart';
import 'renderers/chart_view.dart';
import 'renderers/flashcards_view.dart';
import 'renderers/quiz_view.dart';
import 'renderers/slides_view.dart';
import 'renderers/svg_view.dart';
import 'renderers/web_view.dart';

EveryIcon iconOf(VisualKind kind) => switch (kind) {
  VisualKind.document => EveryIcon.document,
  VisualKind.code || VisualKind.html => EveryIcon.code,
  VisualKind.svg => EveryIcon.image,
  VisualKind.diagram => EveryIcon.diagram,
  VisualKind.chart => EveryIcon.chart,
  VisualKind.quiz => EveryIcon.quiz,
  VisualKind.flashcards => EveryIcon.cards,
  VisualKind.slides => EveryIcon.slides,
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
      VisualKind.html => WebContentView(html: content, fallbackSource: content, height: expanded ? null : 360),
      VisualKind.svg => SvgView(svg: visual.args['svg'] as String? ?? content, maxHeight: expanded ? 900 : 420),
      VisualKind.diagram => () {
        final source = visual.args['mermaid'] as String? ?? content;
        return WebContentView(
          html: mermaidPage(source, dark: dark),
          fallbackSource: source,
          height: expanded ? null : 340,
        );
      }(),
      VisualKind.chart => ChartView(visual: visual, height: expanded ? 380 : 260),
      VisualKind.quiz => QuizView(visual: visual, conversationId: conversationId),
      VisualKind.flashcards => FlashcardsView(visual: visual, height: expanded ? 300 : 210),
      VisualKind.slides => SlidesView(visual: visual, showNotes: expanded),
    };
  }
}

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
    final visual = Visual.fromPart(part);
    if (visual == null) {
      return Text('Used ${part.toolName}', style: TextStyle(color: theme.textMuted, fontSize: 13));
    }
    final panel = ref.read(artifactPanelProvider(conversationId).notifier);
    final isArtifact = part.toolName == 'create_artifact' || part.toolName == 'update_artifact';
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
      if (part.toolName == 'update_artifact') 'Updated ${visual.kind.label.toLowerCase()}' else visual.kind.label,
      switch (visual.kind) {
        VisualKind.quiz => '${(visual.args['questions'] as List?)?.length ?? 0} questions',
        VisualKind.flashcards => '${(visual.args['cards'] as List?)?.length ?? 0} cards',
        VisualKind.slides => '${slidesOf(visual).length} slides',
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
        AdaptiveIconButton(icon: EveryIcon.openPanel, tooltip: 'Open in side panel', onPressed: open),
      ],
    );

    final card = Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      constraints: const BoxConstraints(maxWidth: 680),
      decoration: BoxDecoration(
        color: theme.surfaceRaised,
        borderRadius: BorderRadius.circular(theme.radius + 4),
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
