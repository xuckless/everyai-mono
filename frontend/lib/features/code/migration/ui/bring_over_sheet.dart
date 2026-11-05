// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/router.dart';
import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../questions/ui/question_card.dart' show ChoiceMark;
import '../../../skills/ui/skills_settings_screen.dart' show importSkillCandidates;
import '../../code_providers.dart';
import '../migration_providers.dart';
import '../migration_scan.dart';

/// "Bring over from other tools": a checklist of what Claude Code, Cursor, Codex and OpenCode keep. The scan runs
/// when this opens; nothing is copied until Import selected, and the other tools' files are never changed.
Future<void> showBringOver(BuildContext context) => showGeneralDialog<void>(
  context: context,
  useRootNavigator: true,
  barrierDismissible: true,
  barrierLabel: 'Close',
  barrierColor: const Color(0x33000000),
  pageBuilder: (_, _, _) => const BringOverSheet(),
);

class BringOverSheet extends ConsumerStatefulWidget {
  const BringOverSheet({super.key});

  @override
  ConsumerState<BringOverSheet> createState() => _BringOverSheetState();
}

class _BringOverSheetState extends ConsumerState<BringOverSheet> {
  /// Rows the user ticked or unticked; the rest start as the scan says.
  final _picked = <String, bool>{};
  List<String>? _result;
  bool _busy = false;

  static String _key(ImportItem i) => '${i.kind.name}|${i.source}|${i.scope}|${i.title}';

  bool _on(ImportItem i) => i.selectable && (_picked[_key(i)] ?? i.checked);

  Future<void> _import(List<ImportItem> items) async {
    setState(() => _busy = true);
    final lines = await ref.read(importApplierProvider)([
      for (final i in items)
        if (_on(i)) i,
    ], skills: (candidates) => importSkillCandidates(context, ref, candidates));
    if (mounted) {
      setState(() {
        _busy = false;
        _result = lines;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final scan = ref.watch(migrationScanProvider);
    final items = scan.value ?? const <ImportItem>[];
    final chosen = items.where(_on).length;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
        child: GlassSurface(
          level: GlassLevel.thick,
          radius: EveryTheme.cardRadius,
          padding: const EdgeInsets.all(18),
          child: DefaultTextStyle(
            style: theme.type.body.tint(theme.text),
            child: CallbackShortcuts(
              bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).pop()},
              child: FocusScope(
                autofocus: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Bring over from other tools', style: theme.type.headline.tint(theme.text)),
                    const SizedBox(height: 4),
                    Text(
                      "Tick what you want in EveryAI. Nothing is copied until you press Import, and the other tools' "
                      'files are never changed.',
                      style: theme.type.caption.tint(theme.textMuted),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: switch (scan) {
                        _ when _result != null => _Result(lines: _result!),
                        AsyncError() => Text(
                          "Couldn't look through the other tools' folders.",
                          style: theme.type.callout.tint(theme.textMuted),
                        ),
                        AsyncLoading() => const Center(child: AdaptiveProgress()),
                        _ => _List(items: items, on: _on, toggle: (i) => setState(() => _picked[_key(i)] = !_on(i))),
                      },
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        AdaptiveButton(
                          key: const ValueKey('bring-over.close'),
                          label: _result == null ? 'Cancel' : 'Done',
                          emphasis: ButtonEmphasis.secondary,
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                        if (_result == null) ...[
                          const SizedBox(width: 8),
                          AdaptiveButton(
                            key: const ValueKey('bring-over.import'),
                            label: 'Import selected ($chosen)',
                            busy: _busy,
                            onPressed: chosen == 0 ? null : () => _import(items),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _List extends ConsumerWidget {
  const _List({required this.items, required this.on, required this.toggle});

  final List<ImportItem> items;
  final bool Function(ImportItem) on;
  final void Function(ImportItem) toggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final projects = ref.watch(codeProjectsProvider);
    String? scopeLabel(ImportItem i) =>
        i.scope == null ? null : 'Project ${projects.where((p) => p.path == i.scope).firstOrNull?.name ?? i.scope}';
    return ListView(
      children: [
        if (items.every((i) => i.kind == ImportKind.rule))
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'No MCP servers, commands, agents or skills found.',
              style: theme.type.callout.tint(theme.textMuted),
            ),
          ),
        for (final kind in ImportKind.values)
          if (items.any((i) => i.kind == kind)) ...[
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 4),
              child: Text(kind.label, style: theme.type.callout.semibold.tint(theme.text)),
            ),
            if (kind == ImportKind.rule)
              Text(
                'Kept where they are. EveryAI reads AGENTS.md and CLAUDE.md as they are.',
                style: theme.type.caption.tint(theme.textMuted),
              ),
            if (kind == ImportKind.mcp)
              Text(
                'You approve each local command in MCP servers before it runs.',
                style: theme.type.caption.tint(theme.textMuted),
              ),
            for (final i in items.where((i) => i.kind == kind))
              _Row(item: i, on: on(i), scope: scopeLabel(i), onTap: i.selectable ? () => toggle(i) : null),
          ],
        const SizedBox(height: 14),
        Text('Earlier sessions', style: theme.type.callout.semibold.tint(theme.text)),
        const SizedBox(height: 2),
        Text(
          'Open Code and pick a project: its earlier sessions from every tool are listed there, and you can pick '
          'one up where it stopped.',
          style: theme.type.caption.tint(theme.textMuted),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: AdaptiveButton(
            key: const ValueKey('bring-over.sessions'),
            label: 'Open Code',
            emphasis: ButtonEmphasis.secondary,
            onPressed: () {
              final router = GoRouter.of(context);
              Navigator.of(context, rootNavigator: true).popUntil((r) => r.isFirst);
              router.go(Routes.code);
            },
          ),
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.item, required this.on, required this.scope, required this.onTap});

  final ImportItem item;
  final bool on;
  final String? scope;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final muted = theme.type.caption.tint(theme.textMuted);
    final rule = item.kind == ImportKind.rule;
    return GestureDetector(
      key: ValueKey('bring-over.row.${item.kind.name}.${item.source}.${item.scope}.${item.title}'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 26,
              child: rule
                  ? null
                  : Opacity(
                      opacity: item.selectable ? 1 : 0.35,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: ChoiceMark(multiple: true, selected: on),
                      ),
                    ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    style: theme.type.callout.medium.tint(item.selectable || rule ? theme.text : theme.textMuted),
                  ),
                  Text([item.source, ?scope].join(' · '), style: muted),
                  if (item.detail.isNotEmpty) Text(item.detail, style: muted.mono, maxLines: 2),
                  if (item.unavailable != null) Text(item.unavailable!, style: muted),
                  for (final n in item.notes) Text(n, style: muted),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Result extends StatelessWidget {
  const _Result({required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return ListView(
      children: [
        for (final l in lines)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text(l, style: theme.type.callout.tint(theme.text)),
          ),
        if (lines.isEmpty) Text('Nothing was imported.', style: theme.type.callout.tint(theme.textMuted)),
      ],
    );
  }
}
