import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../artifact_providers.dart';
import '../domain/artifact.dart';
import '../export/downloads.dart';
import 'download_button.dart';
import 'renderers/web_view.dart';
import 'visual_view.dart';

/// The side panel beside a chat: the open artifact (with its versions) or a
/// visual at full size, with copy, save and close.
class ArtifactPanel extends ConsumerWidget {
  const ArtifactPanel({super.key, required this.conversationId});

  final String conversationId;

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
    final v = visual;
    final export = exportOf(v);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.surface,
        border: Border(left: BorderSide(color: theme.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 52,
            padding: const EdgeInsets.only(left: 16, right: 6),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: theme.border)),
            ),
            child: Row(
              children: [
                AdaptiveIcon(iconOf(v.kind), size: 17, color: theme.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        artifact?.title ?? v.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: theme.text, fontWeight: FontWeight.w600, fontSize: 14),
                      ),
                      Text(
                        [
                          v.kind == VisualKind.code && v.str('language').isNotEmpty ? v.str('language') : v.kind.label,
                          if (artifact != null && artifact.versions.length > 1)
                            'Version ${version + 1} of ${artifact.versions.length}',
                        ].join(' · '),
                        style: TextStyle(color: theme.textMuted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                if (artifact != null && artifact.versions.length > 1) ...[
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
                if (v.kind == VisualKind.html || v.kind == VisualKind.diagram)
                  AdaptiveIconButton(
                    icon: EveryIcon.external,
                    tooltip: 'Open in browser',
                    onPressed: () => openHtmlInBrowser(
                      v.kind == VisualKind.html
                          ? v.str('content')
                          : mermaidPage(v.args['mermaid'] as String? ?? v.str('content'), dark: false),
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
                AdaptiveIconButton(icon: EveryIcon.close, tooltip: 'Close panel', onPressed: panel.close),
              ],
            ),
          ),
          Expanded(
            child: v.kind == VisualKind.html || v.kind == VisualKind.diagram
                ? Padding(
                    padding: const EdgeInsets.all(12),
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
    );
  }
}
