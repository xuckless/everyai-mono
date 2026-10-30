import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../domain/artifact.dart';
import '../export/downloads.dart';

/// Saves a visual: straight away when it has one format, otherwise a menu
/// (Markdown, PDF, Word… for documents).
class DownloadButton extends StatelessWidget {
  const DownloadButton({super.key, required this.visual});

  final Visual visual;

  static Future<void> save(BuildContext context, Visual visual, DownloadOption option) async {
    final location = await getSaveLocation(suggestedName: '${exportOf(visual).name}.${option.extension}');
    if (location == null) return;
    try {
      await File(location.path).writeAsBytes(await option.build());
      if (context.mounted) showAdaptiveToast(context, 'Saved');
    } on Object catch (e) {
      if (context.mounted) showAdaptiveToast(context, 'Could not save: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final options = downloadsOf(visual);
    if (options.length == 1) {
      return AdaptiveIconButton(
        icon: EveryIcon.download,
        tooltip: 'Download ${options.first.label}',
        onPressed: () => save(context, visual, options.first),
      );
    }
    final theme = EveryTheme.of(context);
    return AdaptiveMenuButton(
      tooltip: 'Download',
      actions: [
        for (final o in options)
          MenuAction(label: '${o.label} (.${o.extension})', onSelected: () => save(context, visual, o)),
      ],
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: AdaptiveIcon(EveryIcon.download, size: 18, color: theme.text.withValues(alpha: 0.85)),
      ),
    );
  }
}
