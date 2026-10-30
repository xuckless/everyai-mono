import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/adaptive_page.dart';
import '../../../core/ui/every_icons.dart';
import '../domain/model_catalog.dart';
import '../models_providers.dart';
import 'model_avatar.dart';

/// Every model, grouped by provider, with library membership and default selection.
class ModelsScreen extends ConsumerStatefulWidget {
  const ModelsScreen({super.key});

  @override
  ConsumerState<ModelsScreen> createState() => _ModelsScreenState();
}

class _ModelsScreenState extends ConsumerState<ModelsScreen> {
  Modality? _filter;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final catalog = ref.watch(modelCatalogProvider);
    final library = ref.watch(libraryProvider);
    final defaultModel = ref.watch(defaultModelProvider);
    final inLibrary = {...?library.value?.map((s) => s.id)};

    return AdaptivePage(
      title: 'Models',
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 8, 16, 32),
        children: [
          Wrap(
            spacing: 8,
            children: [
              for (final (label, value) in [('All', null), ...Modality.values.map((m) => (m.label, m))])
                _FilterChip(label: label, selected: _filter == value, onTap: () => setState(() => _filter = value)),
            ],
          ),
          for (final provider in ModelProvider.values)
            if (catalog.byProvider(provider).where((s) => _filter == null || s.output == _filter).toList()
                case final specs when specs.isNotEmpty) ...[
              AdaptiveSectionHeader('${provider.label} · ${provider.company}'),
              for (final spec in specs)
                AdaptiveListTile(
                  leading: Opacity(opacity: spec.available ? 1 : 0.5, child: ModelAvatar(provider, size: 32)),
                  title: Text(spec.name),
                  subtitle: Text(
                    [
                      if (spec.blurb.isNotEmpty) spec.blurb,
                      if (spec == defaultModel) 'Default for new chats',
                      if (!spec.available) 'Not available yet',
                    ].join(' · '),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AdaptiveMenuButton(
                        tooltip: 'Model options',
                        actions: [
                          MenuAction(
                            label: 'Use for new chats',
                            checked: spec == defaultModel,
                            onSelected: () => ref.read(defaultModelProvider.notifier).set(spec),
                          ),
                        ],
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: AdaptiveIcon(EveryIcon.more, size: 16, color: theme.textMuted),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Semantics(
                        label: 'In library',
                        child: AdaptiveSwitch(
                          value: inLibrary.contains(spec.id),
                          onChanged: spec.available ? (_) => ref.read(libraryProvider.notifier).toggle(spec) : null,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        onTap: onTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: selected ? theme.accent : theme.surfaceRaised,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: selected ? theme.onAccent : theme.text,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
