import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/anchored_popover.dart';
import '../../../core/ui/every_icons.dart';
import '../../models/domain/model_catalog.dart';
import '../../models/models_providers.dart';
import '../agent_models.dart';
import '../domain/agent_menu.dart';

/// The agent menu: Harness → Model (grouped by vendor, tiers as hints) →
/// Effort, as submenus inside one popover on every design language (never a
/// bottom sheet). [onChanged] gets the new model and effort ('' is the
/// model's default); an open session applies it live.
class AgentMenu extends ConsumerWidget {
  const AgentMenu({
    super.key,
    required this.model,
    required this.effort,
    required this.onChanged,
    this.harness = CodeHarnessKind.openHands,
    this.bordered = false,
  });

  final String model;
  final String effort;
  final void Function(String model, String effort) onChanged;
  final CodeHarnessKind harness;

  /// A pill outline, for the page header.
  final bool bordered;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final catalog = ref.watch(agentCatalogProvider);
    final specs = ref.watch(modelCatalogProvider);
    final groups = agentMenuGroups(catalog, current: model, nameOf: (id) => specs[ModelId(id)]?.name);
    final current = [for (final (_, ms) in groups) ...ms].where((m) => m.model == model).firstOrNull;
    final label = agentMenuLabel(current?.name ?? model.split('/').last, effort);
    return AnchoredPopover(
      width: 320,
      builder: (context, close) => AgentMenuPanel(
        groups: groups,
        model: model,
        effort: effort,
        harness: harness,
        reasons: specs[ModelId(model)]?.reasoning ?? true,
        onChanged: onChanged,
        close: close,
      ),
      child: Semantics(
        button: true,
        label: 'Agent model: $label',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: bordered
              ? BoxDecoration(
                  border: Border.all(color: theme.border),
                  borderRadius: BorderRadius.circular(8),
                )
              : null,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.type.callout.tint(theme.textMuted),
                ),
              ),
              const SizedBox(width: 4),
              AdaptiveIcon(EveryIcon.chevronDown, size: 11, color: theme.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

enum _Page { root, harness, model, effort }

/// The popover's content: a root list whose rows open their submenu in place,
/// with a back row to return.
class AgentMenuPanel extends StatefulWidget {
  const AgentMenuPanel({
    super.key,
    required this.groups,
    required this.model,
    required this.effort,
    required this.harness,
    required this.onChanged,
    required this.close,
    this.reasons = true,
  });

  final List<(ModelProvider, List<AgentMenuModel>)> groups;
  final String model;
  final String effort;
  final CodeHarnessKind harness;

  /// Whether the current model takes an effort at all.
  final bool reasons;
  final void Function(String model, String effort) onChanged;
  final VoidCallback close;

  @override
  State<AgentMenuPanel> createState() => _AgentMenuPanelState();
}

class _AgentMenuPanelState extends State<AgentMenuPanel> {
  var _page = _Page.root;

  // Reflects a pick at once, before the parent rebuilds with it.
  late String _model = widget.model;
  late String _effort = widget.effort;

  @override
  void didUpdateWidget(AgentMenuPanel old) {
    super.didUpdateWidget(old);
    if (old.model != widget.model) _model = widget.model;
    if (old.effort != widget.effort) _effort = widget.effort;
  }

  AgentMenuModel? get _current =>
      [for (final (_, ms) in widget.groups) ...ms].where((m) => m.model == _model).firstOrNull;

  void _pick(String model, String effort) {
    setState(() {
      _model = model;
      _effort = effort;
      _page = _Page.root;
    });
    widget.onChanged(model, effort);
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    Widget check(bool on) => on ? AdaptiveIcon(EveryIcon.check, size: 14, color: theme.accent) : const SizedBox();
    final more = AdaptiveIcon(EveryIcon.chevronRight, size: 12, color: theme.textMuted);
    final current = _current;

    final rows = switch (_page) {
      _Page.root => [
        const PopoverHeader('Agent'),
        PopoverRow(
          key: const ValueKey('agent-menu.harness'),
          title: 'Harness',
          subtitle: widget.harness.label,
          trailing: more,
          onTap: () => setState(() => _page = _Page.harness),
        ),
        PopoverRow(
          key: const ValueKey('agent-menu.model'),
          title: 'Model',
          subtitle: [
            current?.name ?? _model.split('/').last,
            if (current?.tierHint case final h? when h.isNotEmpty) h,
          ].join(' · '),
          trailing: more,
          onTap: () => setState(() => _page = _Page.model),
        ),
        PopoverRow(
          key: const ValueKey('agent-menu.effort'),
          title: 'Effort',
          subtitle: widget.reasons ? effortLabel(_effort) : 'Not used by this model',
          trailing: more,
          onTap: widget.harness == CodeHarnessKind.demo ? null : () => setState(() => _page = _Page.effort),
        ),
      ],
      _Page.harness => [
        _Back('Harness', onTap: () => setState(() => _page = _Page.root)),
        for (final h in CodeHarnessKind.menuFor(widget.harness))
          PopoverRow(
            title: h.label,
            subtitle: h.blurb,
            selected: h == widget.harness,
            trailing: check(h == widget.harness),
            // One harness per session for now: the others are placeholders.
            onTap: h.available && h == widget.harness ? () => setState(() => _page = _Page.root) : null,
          ),
      ],
      _Page.model => [
        _Back('Model', onTap: () => setState(() => _page = _Page.root)),
        for (final (vendor, models) in widget.groups) ...[
          PopoverHeader(vendor.company),
          for (final m in models)
            PopoverRow(
              key: ValueKey('agent-menu.model.${m.model}'),
              title: m.name,
              subtitle: m.tierHint.isEmpty ? null : m.tierHint,
              selected: m.model == _model,
              trailing: check(m.model == _model),
              onTap: m.model == _model
                  ? () => setState(() => _page = _Page.root)
                  : () => _pick(m.model, effortForModel(m, _effort)),
            ),
        ],
      ],
      _Page.effort => [
        _Back('Effort', onTap: () => setState(() => _page = _Page.root)),
        for (final e in agentMenuEfforts)
          PopoverRow(
            key: ValueKey('agent-menu.effort.${e.isEmpty ? 'default' : e}'),
            title: effortLabel(e),
            subtitle: [
              effortBlurb(e),
              if (current != null && e.isNotEmpty && current.efforts.contains(e))
                e == current.recommendedEffort ? 'recommended' : 'tested',
            ].where((s) => s.isNotEmpty).join(' · '),
            selected: e == _effort,
            trailing: check(e == _effort),
            onTap: !widget.reasons
                ? null
                : e == _effort
                ? () => setState(() => _page = _Page.root)
                : () => _pick(_model, e),
          ),
      ],
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
      ),
    );
  }
}

class _Back extends StatelessWidget {
  const _Back(this.title, {required this.onTap});

  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return PopoverRow(
      key: const ValueKey('agent-menu.back'),
      title: title,
      leading: AdaptiveIcon(EveryIcon.chevronLeft, size: 12, color: theme.textMuted),
      onTap: onTap,
    );
  }
}
