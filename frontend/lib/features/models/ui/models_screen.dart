import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/adaptive_page.dart';
import '../../../core/ui/brand.dart';
import '../../../core/ui/every_icons.dart';
import '../domain/model_catalog.dart';
import '../models_providers.dart';
import 'model_avatar.dart';

enum _Filter {
  all('All'),
  mine('My models'),
  free('Free'),
  image('Image'),
  vision('Vision'),
  tools('Tools'),
  reasoning('Reasoning');

  const _Filter(this.label);
  final String label;

  bool test(ModelSpec s, Set<ModelId> mine) => switch (this) {
    all => true,
    _Filter.mine => mine.contains(s.id),
    free => s.free,
    image => s.output == Modality.image,
    vision => s.imageInput,
    tools => s.tools,
    reasoning => s.reasoning,
  };
}

/// The model shop: every model the backend offers, searchable and filterable,
/// with prices (per million input / output tokens). "Add" puts a model in My
/// models, the composer's picker list.
class ModelsScreen extends ConsumerStatefulWidget {
  const ModelsScreen({super.key});

  @override
  ConsumerState<ModelsScreen> createState() => _ModelsScreenState();
}

class _ModelsScreenState extends ConsumerState<ModelsScreen> {
  _Filter _filter = _Filter.all;
  ModelProvider? _provider;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final catalog = ref.watch(modelCatalogProvider);
    final library = ref.watch(libraryProvider).value ?? const <ModelSpec>[];
    final defaultModel = ref.watch(defaultModelProvider);
    final mine = {for (final s in library) s.id};
    final q = _query.trim().toLowerCase();

    // Providers with the most models first.
    final providers = catalog.providers.toList()
      ..sort((a, b) => catalog.byProvider(b).length.compareTo(catalog.byProvider(a).length));

    final source = _filter == _Filter.mine ? library : catalog.all;
    final models = source
        .where(
          (s) =>
              _filter.test(s, mine) &&
              (_provider == null || s.provider == _provider) &&
              (q.isEmpty ||
                  s.name.toLowerCase().contains(q) ||
                  s.id.value.toLowerCase().contains(q) ||
                  s.provider.company.toLowerCase().contains(q) ||
                  s.blurb.toLowerCase().contains(q)),
        )
        .toList(growable: false);

    final header = <Widget>[
      AdaptiveTextField(
        placeholder: 'Search ${catalog.length} models',
        prefix: AdaptiveIcon(EveryIcon.search, size: 16, color: theme.textMuted),
        onChanged: (v) => setState(() => _query = v),
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final f in _Filter.values)
            _FilterChip(
              label: f == _Filter.mine ? '${f.label} (${library.length})' : f.label,
              selected: _filter == f,
              onTap: () => setState(() => _filter = f),
            ),
        ],
      ),
      const SizedBox(height: 8),
      SizedBox(
        height: 34,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (final p in [null, ...providers.take(24)])
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: _FilterChip(
                  label: p == null ? 'Any provider' : p.company,
                  leading: p == null ? null : ModelAvatar(p, size: 16),
                  selected: _provider == p,
                  subtle: true,
                  onTap: () => setState(() => _provider = p),
                ),
              ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 4),
        child: Text(
          '${models.length} models · prices per million input / output tokens',
          style: TextStyle(color: theme.textMuted, fontSize: 12),
        ),
      ),
    ];

    return AdaptivePage(
      title: 'Model shop',
      body: ListView.builder(
        padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 8, 16, 32),
        itemCount: header.length + (models.isEmpty ? 1 : models.length),
        itemBuilder: (context, i) {
          if (i < header.length) return header[i];
          if (models.isEmpty) {
            final filtered = q.isNotEmpty || _provider != null || _filter != _Filter.all;
            return Padding(
              padding: const EdgeInsets.only(top: 48),
              child: BrandEmptyState(
                kind: 'no-results',
                title: _filter == _Filter.mine && q.isEmpty && _provider == null
                    ? 'No models yet'
                    : filtered
                    ? 'No models match'
                    : 'The catalog is empty',
                message: _filter == _Filter.mine && q.isEmpty && _provider == null
                    ? 'Add models from All to see them in the picker.'
                    : filtered
                    ? 'Try another search or clear the filters.'
                    : 'It could not be loaded. Check the connection and reopen this page.',
              ),
            );
          }
          final spec = models[i - header.length];
          return _ModelTile(
            spec: spec,
            added: mine.contains(spec.id),
            isDefault: spec == defaultModel,
            onToggle: () => ref.read(libraryProvider.notifier).toggle(spec),
            onMakeDefault: () => ref.read(defaultModelProvider.notifier).set(spec),
          );
        },
      ),
    );
  }
}

class _ModelTile extends StatelessWidget {
  const _ModelTile({
    required this.spec,
    required this.added,
    required this.isDefault,
    required this.onToggle,
    required this.onMakeDefault,
  });

  final ModelSpec spec;
  final bool added;
  final bool isDefault;
  final VoidCallback onToggle;
  final VoidCallback onMakeDefault;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final meta = [
      spec.provider.company,
      if (spec.contextLength > 0) '${spec.contextLabel} context',
      if (spec.output == Modality.image) 'Image output',
      if (isDefault) 'Default for new chats',
    ].join(' · ');
    return AdaptiveListTile(
      leading: ModelAvatar(spec.provider, size: 32),
      title: Row(
        children: [
          Flexible(child: Text(spec.name, overflow: TextOverflow.ellipsis)),
          if (spec.priceLabel case final price?) ...[const SizedBox(width: 8), _Badge(price, highlight: spec.free)],
        ],
      ),
      subtitle: Text(spec.blurb.isEmpty ? meta : '${spec.blurb}\n$meta', maxLines: 3, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AdaptiveMenuButton(
            tooltip: 'Model options',
            actions: [
              MenuAction(label: 'Use for new chats', checked: isDefault, onSelected: onMakeDefault),
              MenuAction(label: added ? 'Remove from My models' : 'Add to My models', onSelected: onToggle),
            ],
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: AdaptiveIcon(EveryIcon.more, size: 16, color: theme.textMuted),
            ),
          ),
          const SizedBox(width: 4),
          AdaptiveButton(
            label: added ? 'Added' : 'Add',
            emphasis: added ? ButtonEmphasis.secondary : ButtonEmphasis.primary,
            onPressed: onToggle,
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text, {this.highlight = false});

  final String text;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: highlight ? theme.accent.withValues(alpha: 0.15) : theme.surfaceRaised,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: highlight ? theme.accent : theme.textMuted,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.leading,
    this.subtle = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget? leading;
  final bool subtle;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final fg = selected ? theme.onPrimary : theme.text;
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        onTap: onTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: EdgeInsets.symmetric(horizontal: subtle ? 10 : 14, vertical: subtle ? 6 : 7),
            decoration: BoxDecoration(
              color: selected ? theme.primary : theme.surfaceRaised,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (leading != null) ...[leading!, const SizedBox(width: 6)],
                Text(
                  label,
                  style: TextStyle(color: fg, fontSize: subtle ? 12 : 13, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
