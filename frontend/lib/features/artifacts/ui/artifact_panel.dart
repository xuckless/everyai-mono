import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../artifact_providers.dart';
import '../domain/artifact.dart';
import '../export/pptx_writer.dart';
import 'renderers/slides_view.dart';
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
                if (!kIsWeb)
                  AdaptiveIconButton(
                    icon: EveryIcon.download,
                    tooltip: v.kind == VisualKind.slides
                        ? 'Save as PowerPoint'
                        : 'Save as ${export.extension.toUpperCase()}',
                    onPressed: () => v.kind == VisualKind.slides ? _savePptx(context, v) : _save(context, export),
                  ),
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

  static Future<void> _save(BuildContext context, ({String text, String name, String extension}) export) async {
    final location = await getSaveLocation(suggestedName: '${export.name}.${export.extension}');
    if (location == null) return;
    await File(location.path).writeAsString(export.text);
    if (context.mounted) showAdaptiveToast(context, 'Saved');
  }
}

Future<void> _savePptx(BuildContext context, Visual v) async {
  final name = exportOf(v).name;
  final location = await getSaveLocation(suggestedName: '$name.pptx');
  if (location == null) return;
  await File(location.path).writeAsBytes(pptxOf(v));
  if (context.mounted) showAdaptiveToast(context, 'Saved');
}

/// The deck in [v] as a PowerPoint file.
Uint8List pptxOf(Visual v) {
  final deck = DeckTheme.of(v.str('theme'));
  String hex(Color c) => (c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();
  final slides = slidesOf(v);
  return buildPptx(
    title: v.title,
    colors: (background: hex(deck.background), title: hex(deck.title), text: hex(deck.text), accent: hex(deck.accent)),
    slides: [
      for (final (i, s) in slides.indexed)
        (title: s.title, bullets: s.bullets, body: s.body, notes: s.notes, isTitle: i == 0),
    ],
  );
}

/// What Copy and Save produce for a visual.
({String text, String name, String extension}) exportOf(Visual v) {
  final name = v.title.replaceAll(RegExp(r'[^\w\- ]+'), '').trim().replaceAll(' ', '-').toLowerCase();
  final safe = name.isEmpty ? 'artifact' : name;
  return switch (v.kind) {
    VisualKind.document => (text: v.str('content'), name: safe, extension: 'md'),
    VisualKind.code => (text: v.str('content'), name: safe, extension: _extensionFor(v.str('language'))),
    VisualKind.html => (text: v.str('content'), name: safe, extension: 'html'),
    VisualKind.svg => (text: v.args['svg'] as String? ?? v.str('content'), name: safe, extension: 'svg'),
    VisualKind.diagram => (text: v.args['mermaid'] as String? ?? v.str('content'), name: safe, extension: 'mmd'),
    VisualKind.chart => (text: const JsonEncoder.withIndent('  ').convert(v.args), name: safe, extension: 'json'),
    VisualKind.quiz => (text: _quizMarkdown(v), name: safe, extension: 'md'),
    VisualKind.flashcards => (
      text: [
        for (final c in (v.args['cards'] as List<Object?>?) ?? const [])
          if (c case {'front': final String f, 'back': final String b}) '$f\t$b',
      ].join('\n'),
      name: safe,
      extension: 'tsv',
    ),
    VisualKind.slides => (
      text: [
        for (final s in slidesOf(v))
          ['# ${s.title}', for (final b in s.bullets) '- $b', if (s.body.isNotEmpty) s.body].join('\n'),
      ].join('\n\n---\n\n'),
      name: safe,
      extension: 'md',
    ),
  };
}

String _quizMarkdown(Visual v) {
  final b = StringBuffer('# ${v.title}\n');
  for (final (i, q) in ((v.args['questions'] as List<Object?>?) ?? const []).indexed) {
    if (q is! Map) continue;
    b.write('\n${i + 1}. ${q['question']}\n');
    for (final (oi, o) in ((q['options'] as List<Object?>?) ?? const []).indexed) {
      b.write('   ${String.fromCharCode(65 + oi)}. $o\n');
    }
  }
  return b.toString();
}

String _extensionFor(String language) => switch (language.toLowerCase()) {
  'python' || 'py' => 'py',
  'javascript' || 'js' => 'js',
  'typescript' || 'ts' => 'ts',
  'dart' => 'dart',
  'zig' => 'zig',
  'rust' || 'rs' => 'rs',
  'go' => 'go',
  'java' => 'java',
  'kotlin' => 'kt',
  'swift' => 'swift',
  'c' => 'c',
  'cpp' || 'c++' => 'cpp',
  'csharp' || 'c#' => 'cs',
  'ruby' => 'rb',
  'php' => 'php',
  'html' => 'html',
  'css' => 'css',
  'sql' => 'sql',
  'shell' || 'bash' || 'sh' => 'sh',
  'json' => 'json',
  'yaml' || 'yml' => 'yaml',
  _ => 'txt',
};
