import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/anchored_popover.dart';
import '../../../core/ui/every_icons.dart';
import '../../models/domain/model_catalog.dart';
import '../../models/models_providers.dart';
import '../../models/ui/model_avatar.dart';
import '../../local_models/local_model_bridge.dart';
import '../../local_models/ui/local_models_section.dart' show showLocalModelSetup;
import '../../../core/platform/platform_kind.dart';
import '../domain/reasoning_effort.dart';
import '../../../core/motion/motion.dart';

/// Composer chip showing the active model. Opens a picker with My models
/// (name + one-line description), a search over the whole shop, and a link to
/// the shop window.
class ModelChip extends ConsumerWidget {
  const ModelChip({
    super.key,
    required this.selected,
    required this.onSelected,
    this.enabled = true,
    this.pickerKey,
    this.effort,
    this.onEffortChanged,
  });

  final ModelSpec selected;

  /// Thinking effort, shown as a segmented row at the top of the picker (reasoning models).
  final ReasoningEffort? effort;
  final ValueChanged<ReasoningEffort>? onEffortChanged;
  final ValueChanged<ModelSpec> onSelected;
  final bool enabled;

  /// Lets the composer open the picker without a tap.
  final GlobalKey<AnchoredPopoverState>? pickerKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chip = Semantics(
      button: true,
      label: 'Model: ${selected.name}',
      child: IgnorePointer(
        // The popover around it takes the tap.
        child: KitChip(
          label: selected.name,
          strong: true,
          chevron: true,
          leading: ModelAvatar(selected.provider, size: 18),
          onTap: () {},
        ),
      ),
    );
    if (!enabled) return Opacity(opacity: 0.5, child: chip);
    return AnchoredPopover(
      key: pickerKey,
      width: 320,
      builder: (context, close) => _ModelPickerPanel(
        effort: effort,
        onEffortChanged: onEffortChanged,
        selected: selected,
        onSelected: (spec) {
          close();
          onSelected(spec);
        },
        onBrowse: () {
          close();
          context.go(Routes.models);
        },
        onBrowseLocal: () {
          close();
          showLocalModelSetup(context);
        },
      ),
      child: chip,
    );
  }
}

class _ModelPickerPanel extends ConsumerStatefulWidget {
  const _ModelPickerPanel({
    required this.selected,
    required this.onSelected,
    required this.onBrowse,
    required this.onBrowseLocal,
    this.effort,
    this.onEffortChanged,
  });

  final ModelSpec selected;
  final VoidCallback onBrowseLocal;
  final ReasoningEffort? effort;
  final ValueChanged<ReasoningEffort>? onEffortChanged;
  final ValueChanged<ModelSpec> onSelected;
  final VoidCallback onBrowse;

  @override
  ConsumerState<_ModelPickerPanel> createState() => _ModelPickerPanelState();
}

class _ModelPickerPanelState extends ConsumerState<_ModelPickerPanel> {
  String _query = '';
  late var _effort = widget.effort;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final catalog = ref.watch(modelCatalogProvider);
    final library = ref.watch(libraryProvider).value ?? const <ModelSpec>[];
    final local = ref.watch(localModelSpecsProvider);
    final pinned = {...library, widget.selected}.where((s) => !local.contains(s)).toList();
    final q = _query.trim().toLowerCase();
    final matches = q.isEmpty
        ? const <ModelSpec>[]
        : catalog.all
              .where(
                (s) =>
                    !pinned.contains(s) &&
                    (s.name.toLowerCase().contains(q) ||
                        s.id.value.toLowerCase().contains(q) ||
                        s.provider.label.toLowerCase().contains(q) ||
                        s.provider.company.toLowerCase().contains(q)),
              )
              .take(20)
              .toList();

    var index = 0;
    Widget row(ModelSpec spec) => PopoverRow(
      leading: ModelAvatar(spec.provider, size: 22),
      title: spec.name,
      subtitle: spec.free ? 'Free' : null,
      trailing: spec == widget.selected ? AdaptiveIcon(EveryIcon.check, size: 15, color: theme.accentText) : null,
      selected: spec == widget.selected,
      onTap: () => widget.onSelected(spec),
    ).rowIn(index < 12 ? index++ : 12);

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_effort != null && widget.onEffortChanged != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
              child: KitSegmented<ReasoningEffort>(
                key: const ValueKey('model-picker.effort'),
                values: ReasoningEffort.values,
                selected: _effort!,
                width: double.infinity,
                label: (e) => e.label,
                onSelected: (e) {
                  setState(() => _effort = e);
                  widget.onEffortChanged!(e);
                },
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
            child: AdaptiveTextField(
              placeholder: 'Search ${catalog.length} models',
              autofocus: true,
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          if (q.isEmpty) ...[
            for (final spec in pinned) row(spec),
            // Models on this computer, and the way to get some (desktops).
            if (local.isNotEmpty || Host.isDesktop) ...[
              const PopoverHeader('On this computer'),
              for (final spec in local) row(spec),
              if (Host.isDesktop)
                PopoverRow(
                  key: const ValueKey('model-picker.get-local'),
                  title: local.isEmpty ? 'Get local models' : 'More local models',
                  leading: AdaptiveIcon(EveryIcon.add, size: 16, color: theme.textMuted),
                  onTap: () {
                    widget.onBrowseLocal();
                  },
                ),
            ],
          ] else if (matches.isEmpty && !pinned.any((s) => s.name.toLowerCase().contains(q)))
            PopoverRow(title: 'No models match "$_query"')
          else ...[
            for (final spec in pinned.where((s) => s.name.toLowerCase().contains(q))) row(spec),
            for (final spec in matches) row(spec),
          ],
          const SizedBox(height: 4),
          PopoverRow(
            title: 'Model shop',
            leading: AdaptiveIcon(EveryIcon.models, size: 16, color: theme.textMuted),
            onTap: widget.onBrowse,
          ),
        ],
      ),
    );
  }
}
