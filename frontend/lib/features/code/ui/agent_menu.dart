import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/anchored_popover.dart';
import '../../../core/ui/every_icons.dart';
import '../../models/domain/model_catalog.dart';
import '../../billing/billing_providers.dart' show formatMicros;
import '../../models/models_providers.dart';
import '../agent_models.dart';
import '../domain/agent_menu.dart';
import '../settings/agent_prompt.dart' show HarnessMode, HarnessTier;
import '../settings/code_settings.dart' show budgetPresets;
import '../ultra/ultra_access.dart' show ultraAccessProvider;

/// The agent menu: Harness, Harness mode, the tier bar (Efficient → Ultra),
/// Model (the user's own models that can call tools) and Effort, in one
/// popover on every design language (never a bottom sheet). [onChanged] gets
/// the new model and effort ('' is the model's default); an open session
/// applies it live, and [onTier] likewise.
class AgentMenu extends ConsumerWidget {
  const AgentMenu({
    super.key,
    required this.model,
    required this.effort,
    required this.onChanged,
    this.harness = CodeHarnessKind.openHands,
    this.onHarness,
    this.bordered = false,
    this.tier = HarnessTier.efficient,
    this.onTier,
    this.harnessMode = HarnessMode.build,
    this.onHarnessMode,
    this.budget,
    this.onBudget,
  });

  /// Picks Build or Bug fix; null shows the mode without a choice.
  final ValueChanged<HarnessMode>? onHarnessMode;

  final String model;
  final String effort;
  final void Function(String model, String effort) onChanged;
  final CodeHarnessKind harness;
  final HarnessTier tier;

  /// Picks the tier; null hides the bar.
  final ValueChanged<HarnessTier>? onTier;
  final HarnessMode harnessMode;

  /// The spending cap, on the New session page (a session sets it from the
  /// usage meter instead); null [onBudget] hides the row.
  final double? budget;
  final ValueChanged<double?>? onBudget;

  /// Picks the harness (before a session starts); null: fixed for the session.
  final ValueChanged<CodeHarnessKind>? onHarness;

  /// A pill outline, for the page header.
  final bool bordered;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final catalog = ref.watch(agentCatalogProvider);
    final specs = ref.watch(modelCatalogProvider);
    final library = ref.watch(libraryProvider).value ?? const <ModelSpec>[];
    final groups = libraryMenuGroups(library, catalog, current: model, nameOf: (id) => specs[ModelId(id)]?.name);
    final current = [for (final (_, ms) in groups) ...ms].where((m) => m.model == model).firstOrNull;
    final ultraAllowed = ref.watch(ultraAccessProvider).value ?? false;
    final label = [
      agentMenuLabel(current?.name ?? model.split('/').last, effort),
      if (onTier != null) tier.label,
      if (harnessMode == HarnessMode.bugFix) 'Bug fix',
    ].join(' · ');
    return AnchoredPopover(
      width: 320,
      builder: (context, close) => AgentMenuPanel(
        groups: groups,
        model: model,
        effort: effort,
        harness: harness,
        onHarness: onHarness,
        reasons: specs[ModelId(model)]?.reasoning ?? true,
        onChanged: onChanged,
        close: close,
        tier: tier,
        onTier: onTier,
        harnessMode: harnessMode,
        onHarnessMode: onHarnessMode,
        ultraAllowed: ultraAllowed,
        budget: budget,
        onBudget: onBudget,
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

enum _Page { root, harness, model, effort, budget }

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
    this.onHarness,
    this.reasons = true,
    this.tier = HarnessTier.efficient,
    this.onTier,
    this.harnessMode = HarnessMode.build,
    this.onHarnessMode,
    this.ultraAllowed = false,
    this.budget,
    this.onBudget,
  });

  final HarnessTier tier;
  final ValueChanged<HarnessTier>? onTier;
  final HarnessMode harnessMode;
  final ValueChanged<HarnessMode>? onHarnessMode;

  /// The plan allows Ultra (the Max plan).
  final bool ultraAllowed;
  final double? budget;
  final ValueChanged<double?>? onBudget;

  final List<(ModelProvider, List<AgentMenuModel>)> groups;
  final String model;
  final String effort;
  final CodeHarnessKind harness;
  final ValueChanged<CodeHarnessKind>? onHarness;

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
  late HarnessTier _tier = widget.tier;
  late double? _budget = widget.budget;
  late HarnessMode _mode = widget.harnessMode;

  @override
  void didUpdateWidget(AgentMenuPanel old) {
    super.didUpdateWidget(old);
    if (old.model != widget.model) _model = widget.model;
    if (old.effort != widget.effort) _effort = widget.effort;
    if (old.tier != widget.tier) _tier = widget.tier;
    if (old.budget != widget.budget) _budget = widget.budget;
    if (old.harnessMode != widget.harnessMode) _mode = widget.harnessMode;
  }

  /// Why [t] can't be picked, or null.
  String? _blocked(HarnessTier t) => t.everyaiOnly && widget.harness != CodeHarnessKind.everyai
      ? 'EveryAI harness only'
      : t == HarnessTier.ultra && !widget.ultraAllowed
      ? 'On the Max plan'
      : null;

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
          key: const ValueKey('agent-menu.harness-mode'),
          title: 'Harness mode',
          subtitle: _mode == HarnessMode.bugFix
              ? 'Reproduce, triage, research, plan, fix, verify'
              : widget.harness == CodeHarnessKind.everyai
              ? 'Build things, or switch to fix a bug, issue or PR'
              : 'Bug fix needs the EveryAI harness',
          trailing: _ModeSwitch(
            mode: _mode,
            onPick: widget.onHarnessMode == null
                ? null
                : (m) {
                    if (m == HarnessMode.bugFix && widget.harness != CodeHarnessKind.everyai) return;
                    setState(() => _mode = m);
                    widget.onHarnessMode!(m);
                  },
          ),
        ),
        if (widget.onTier != null)
          _TierBar(
            tier: _tier,
            blocked: _blocked,
            onTier: (t) {
              setState(() => _tier = t);
              widget.onTier!(t);
            },
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
        if (widget.onBudget != null)
          PopoverRow(
            key: const ValueKey('agent-menu.budget'),
            title: 'Spending cap',
            subtitle: _budget == null ? 'No cap' : formatMicros((_budget! * 1e6).round()),
            trailing: more,
            onTap: () => setState(() => _page = _Page.budget),
          ),
      ],
      _Page.budget => [
        _Back('Spending cap', onTap: () => setState(() => _page = _Page.root)),
        for (final usd in [null, ...budgetPresets])
          PopoverRow(
            key: ValueKey('agent-menu.budget.${usd ?? 'none'}'),
            title: usd == null ? 'No cap' : formatMicros((usd * 1e6).round()),
            selected: usd == _budget,
            trailing: check(usd == _budget),
            onTap: () {
              setState(() {
                _budget = usd;
                _page = _Page.root;
              });
              widget.onBudget!(usd);
            },
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
            // A session keeps the harness it started on; before one starts
            // any available harness can be picked.
            onTap: !h.available
                ? null
                : h == widget.harness
                ? () => setState(() => _page = _Page.root)
                : widget.onHarness == null
                ? null
                : () {
                    widget.onHarness!(h);
                    setState(() => _page = _Page.root);
                  },
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

/// Build or Bug fix, as a two-way switch.
class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.mode, this.onPick});

  final HarnessMode mode;
  final ValueChanged<HarnessMode>? onPick;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    Widget segment(HarnessMode m) {
      final on = m == mode;
      return GestureDetector(
        key: ValueKey('agent-menu.harness-mode.${m.name}'),
        behavior: HitTestBehavior.opaque,
        onTap: onPick == null || on ? null : () => onPick!(m),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: on ? theme.accent.withValues(alpha: 0.18) : null,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(m.label, style: theme.type.caption.tint(on ? theme.accent : theme.textMuted)),
        ),
      );
    }

    return Semantics(
      label: 'Harness mode: ${mode.label}',
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          border: Border.all(color: theme.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [for (final m in HarnessMode.values) segment(m)]),
      ),
    );
  }
}

/// The progressive tier bar: Efficient · Thorough · Max · Ultra, filled up
/// to the pick, with what the pick does underneath.
class _TierBar extends StatelessWidget {
  const _TierBar({required this.tier, required this.blocked, required this.onTier});

  final HarnessTier tier;
  final String? Function(HarnessTier) blocked;
  final ValueChanged<HarnessTier> onTier;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final tiers = HarnessTier.offered;
    final at = tiers.indexOf(tier);
    final note = blocked(tier);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Tier', style: theme.type.callout),
          const SizedBox(height: 6),
          Row(
            children: [
              for (final (i, t) in tiers.indexed)
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: t == tier,
                    label: 'Tier ${t.label}${blocked(t) == null ? '' : ', ${blocked(t)}'}',
                    child: GestureDetector(
                      key: ValueKey('agent-menu.tier.${t.name}'),
                      behavior: HitTestBehavior.opaque,
                      onTap: blocked(t) == null && t != tier ? () => onTier(t) : null,
                      child: Column(
                        children: [
                          Container(
                            height: 6,
                            margin: EdgeInsets.only(right: i == tiers.length - 1 ? 0 : 3),
                            decoration: BoxDecoration(
                              color: i <= at
                                  ? theme.accent
                                  : blocked(t) == null
                                  ? theme.border
                                  : theme.border.withValues(alpha: 0.4),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            t.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.type.caption.tint(
                              t == tier
                                  ? theme.accent
                                  : blocked(t) == null
                                  ? theme.textMuted
                                  : theme.textMuted.withValues(alpha: 0.5),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            note == null ? tier.description : '${tier.description} · $note',
            style: theme.type.caption.tint(theme.textMuted),
          ),
        ],
      ),
    );
  }
}
