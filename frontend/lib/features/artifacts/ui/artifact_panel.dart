import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../artifact_providers.dart';
import '../../chat/chat_providers.dart';
import '../domain/artifact.dart';
import '../domain/drawing.dart';
import '../export/downloads.dart';
import '../polish/figure_polish.dart';
import 'artifact_editor.dart';
import 'download_button.dart';
import 'renderers/web_view.dart';
import 'visual_view.dart';

/// The side panel beside a chat: the open artifact (with its versions) or a
/// visual at full size, with copy, save and close.
class ArtifactPanel extends ConsumerWidget {
  const ArtifactPanel({super.key, required this.conversationId, this.fullScreen = false});

  final String conversationId;

  /// Covers the chat (phones): a back chevron leads the header instead of the
  /// trailing close button.
  final bool fullScreen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final target = ref.watch(artifactPanelProvider(conversationId));
    final panel = ref.read(artifactPanelProvider(conversationId).notifier);
    final artifacts = ref.watch(conversationArtifactsProvider(conversationId));

    Visual? visual;
    Artifact? artifact;
    var version = 0;
    switch (target) {
      case ArtifactTarget(:final artifactId, version: final v):
        artifact = artifacts.where((a) => a.id == artifactId).firstOrNull;
        if (artifact != null) {
          version = (v ?? artifact.versions.length - 1).clamp(0, artifact.versions.length - 1);
          visual = artifact.versions[version];
        }
      case VisualTarget(visual: final v):
        visual = v;
      case null:
        break;
    }
    if (visual == null) return const SizedBox.shrink();
    void close() {
      ref.read(artifactEditProvider(conversationId).notifier).cancel();
      panel.close();
    }

    final v = visual;
    final export = exportOf(v);
    final interactive = v.kind == VisualKind.html && ref.watch(webInteractiveProvider(webArtifactKey(v)));
    final draft = v.kind == VisualKind.drawing ? ref.watch(drawingDraftProvider(v.callId)) : null;
    final edit = ref.watch(artifactEditProvider(conversationId));
    final editing = edit != null && artifact != null && edit.artifactId == artifact.id ? edit : null;
    final canEdit = artifact != null && editableAsText(v);
    final polishing = v.kind == VisualKind.svg && ref.watch(figurePolishProvider(conversationId));
    final fills =
        editing != null || v.kind == VisualKind.html || v.kind == VisualKind.diagram || v.kind == VisualKind.drawing;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.surface,
        border: Border(left: BorderSide(color: theme.border)),
      ),
      // Below the translucent navigation bar (iOS) and above the home indicator.
      child: SafeArea(
        left: false,
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 52,
              padding: EdgeInsets.only(left: fullScreen ? 4 : 16, right: 6),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: theme.border)),
              ),
              child: Row(
                children: [
                  if (fullScreen) ...[
                    AdaptiveIconButton(icon: EveryIcon.chevronLeft, tooltip: 'Back to chat', onPressed: close),
                    const SizedBox(width: 2),
                  ] else ...[
                    AdaptiveIcon(iconOf(v.kind), size: 17, color: theme.accent),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          artifact?.title ?? v.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.type.body.semibold.tint(theme.text),
                        ),
                        Text(
                          [
                            v.kind == VisualKind.code && v.str('language').isNotEmpty
                                ? v.str('language')
                                : v.kind.label,
                            if (v.kind == VisualKind.html) interactive ? 'Interactive' : 'Static',
                            if (v.kind == VisualKind.drawing && (draft != null || artifact == null)) 'Not saved',
                            if (editing != null)
                              editing.changed ? 'Editing · Not saved' : 'Editing'
                            else ...[
                              if (artifact != null && artifact.versions.length > 1)
                                'Version ${version + 1} of ${artifact.versions.length}',
                              if (v.editedByUser) 'Edited by you',
                            ],
                          ].join(' · '),
                          style: theme.type.caption.tint(theme.textMuted),
                        ),
                      ],
                    ),
                  ),
                  if (editing != null) ...[
                    AdaptiveButton(
                      label: 'Cancel',
                      emphasis: ButtonEmphasis.plain,
                      onPressed: ref.read(artifactEditProvider(conversationId).notifier).cancel,
                    ),
                    const SizedBox(width: 6),
                    AdaptiveButton(label: 'Save', onPressed: editing.changed ? () => _saveEdit(context, ref) : null),
                    const SizedBox(width: 6),
                  ] else if (artifact != null && artifact.versions.length > 1) ...[
                    AdaptiveIconButton(
                      icon: EveryIcon.chevronLeft,
                      tooltip: 'Previous version',
                      onPressed: version == 0 ? null : () => panel.openArtifact(artifact!.id, version: version - 1),
                    ),
                    AdaptiveIconButton(
                      icon: EveryIcon.chevronRight,
                      tooltip: 'Next version',
                      onPressed: version == artifact.versions.length - 1
                          ? null
                          : () => panel.openArtifact(artifact!.id, version: version + 1),
                    ),
                  ],
                  if (canEdit && editing == null)
                    AdaptiveIconButton(
                      icon: EveryIcon.edit,
                      tooltip: 'Edit',
                      onPressed: () => ref.read(artifactEditProvider(conversationId).notifier).start(artifact!.id, v),
                    ),
                  if (v.kind == VisualKind.svg && editing == null)
                    AdaptiveIconButton(
                      icon: EveryIcon.spark,
                      tooltip: polishing ? 'Polishing…' : 'Polish: look at the render and fix what\'s off',
                      onPressed: polishing ? null : () => _polish(context, ref, v, artifact),
                    ),
                  if (v.kind == VisualKind.html && editing == null)
                    AdaptiveIconButton(
                      icon: interactive ? EveryIcon.pause : EveryIcon.play,
                      tooltip: interactive ? 'Show without scripts' : 'Run scripts',
                      onPressed: ref.read(webInteractiveProvider(webArtifactKey(v)).notifier).toggle,
                    ),
                  if (v.kind == VisualKind.drawing)
                    AdaptiveIconButton(
                      icon: EveryIcon.check,
                      tooltip: 'Save as a new version',
                      onPressed: draft == null ? null : () => _saveDrawing(context, ref, v, artifact, draft),
                    ),
                  if (v.kind == VisualKind.diagram && inlineWebSupported && editing == null)
                    AdaptiveIconButton(
                      icon: EveryIcon.drawing,
                      tooltip: 'Make editable',
                      onPressed: () => _makeEditable(ref, v, artifact),
                    ),
                  if ((v.kind == VisualKind.html || v.kind == VisualKind.diagram) && editing == null)
                    AdaptiveIconButton(
                      icon: EveryIcon.external,
                      tooltip: 'Open in browser',
                      onPressed: () => v.kind == VisualKind.html
                          ? openHtmlInBrowser(v.str('content'), interactive: interactive)
                          : openHtmlInBrowser(
                              mermaidPage(v.args['mermaid'] as String? ?? v.str('content'), dark: false),
                              surface: WebSurface.diagram,
                            ),
                    ),
                  AdaptiveIconButton(
                    icon: EveryIcon.copy,
                    tooltip: 'Copy',
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: export.text));
                      if (context.mounted) showAdaptiveToast(context, 'Copied');
                    },
                  ),
                  if (!kIsWeb) DownloadButton(visual: v),
                  if (!fullScreen) AdaptiveIconButton(icon: EveryIcon.close, tooltip: 'Close panel', onPressed: close),
                ],
              ),
            ),
            Expanded(
              child: editing != null
                  ? ArtifactTextEditor(
                      key: ValueKey('edit:${editing.base.callId}'),
                      initialText: editing.text,
                      onChanged: ref.read(artifactEditProvider(conversationId).notifier).update,
                      onSave: () => _saveEdit(context, ref),
                      onCancel: ref.read(artifactEditProvider(conversationId).notifier).cancel,
                    )
                  : fills
                  ? Padding(
                      padding: EdgeInsets.all(v.kind == VisualKind.drawing ? 0 : 12),
                      child: VisualBody(visual: v, conversationId: conversationId, expanded: true),
                    )
                  : SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                      child: VisualBody(
                        key: ValueKey(v.callId),
                        visual: v,
                        conversationId: conversationId,
                        expanded: true,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// One Polish round on the figure [v]; the result is saved as a new version.
  Future<void> _polish(BuildContext context, WidgetRef ref, Visual v, Artifact? artifact) async {
    final message = await ref.read(figurePolishProvider(conversationId).notifier).polish(v, artifact);
    if (context.mounted) showAdaptiveToast(context, message);
  }

  /// Saves the hand-edit as the artifact's newest version and shows it.
  Future<void> _saveEdit(BuildContext context, WidgetRef ref) async {
    final editor = ref.read(artifactEditProvider(conversationId).notifier);
    final id = ref.read(artifactEditProvider(conversationId))?.artifactId;
    if (id == null) return;
    final saved = await editor.save();
    if (!context.mounted) return;
    if (!saved) {
      showAdaptiveToast(context, 'Wait for the answer to finish, then save');
      return;
    }
    ref.read(artifactPanelProvider(conversationId).notifier).openArtifact(id);
    showAdaptiveToast(context, 'Saved as a new version');
  }

  /// Opens the Mermaid diagram [v] as an Excalidraw drawing: the one made
  /// from it before, or a new, unsaved one converted in the editor.
  void _makeEditable(WidgetRef ref, Visual v, Artifact? diagram) {
    final panel = ref.read(artifactPanelProvider(conversationId).notifier);
    final id = drawingIdForDiagram(diagram?.id ?? webArtifactKey(v));
    if (ref.read(conversationArtifactsProvider(conversationId)).any((a) => a.id == id)) {
      panel.openArtifact(id);
      return;
    }
    panel.openVisual(drawingFromDiagram(v, id: id));
  }

  /// Saves the editor's scene: the next version of the drawing, or (for a
  /// converted diagram) a new drawing artifact.
  Future<void> _saveDrawing(BuildContext context, WidgetRef ref, Visual v, Artifact? artifact, String scene) async {
    final chat = ref.read(chatSessionProvider(conversationId).notifier);
    final id = artifact?.id ?? v.str('id');
    final saved = artifact != null
        ? await chat.saveUserArtifact('update_artifact', {'id': id, 'content': scene})
        : await chat.saveUserArtifact('create_artifact', {
            'id': id,
            'title': v.title,
            'kind': 'drawing',
            'content': scene,
          });
    if (!context.mounted) return;
    if (!saved) {
      showAdaptiveToast(context, 'Wait for the answer to finish, then save');
      return;
    }
    ref.read(drawingDraftProvider(v.callId).notifier).clear();
    ref.read(artifactPanelProvider(conversationId).notifier).openArtifact(id);
    showAdaptiveToast(context, 'Saved');
  }
}

/// An unsaved drawing made from the Mermaid diagram [diagram]; the editor
/// converts the source with mermaid-to-excalidraw.
Visual drawingFromDiagram(Visual diagram, {required String id}) => Visual(
  callId: 'make-editable:$id',
  kind: VisualKind.drawing,
  title: diagram.title,
  args: {
    'id': id,
    'title': diagram.title,
    'kind': 'drawing',
    'mermaid': diagram.args['mermaid'] as String? ?? diagram.str('content'),
  },
);
