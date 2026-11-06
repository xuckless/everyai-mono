import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/adaptive_page.dart';
import '../../../core/motion/motion.dart';
import '../../../core/ui/every_icons.dart';
import '../../settings/byok_keys.dart' show modelBillersProvider, modelBillingProvider;
import '../../settings/domain/byok_providers.dart' show Biller, ModelBilling;
import '../domain/model_catalog.dart';
import '../models_providers.dart';
import 'model_avatar.dart';

/// The shop's scope: one at a time.
enum _Filter {
  all('All'),
  mine('My models'),
  free('Free'),
  ownKey('On your keys');

  const _Filter(this.label);
  final String label;

  bool test(ModelSpec s, Set<ModelId> mine, ModelBilling billing) => switch (this) {
    all => true,
    _Filter.mine => mine.contains(s.id),
    ownKey => billing.billersFor(s.id).any((b) => b.isOwnKey),
    free => s.free,
  };
}

/// What a model can do; any number at once, a model must have them all.
enum _Cap {
  tools('Tools'),
  vision('Vision'),
  reasoning('Reasoning'),
  image('Makes images');

  const _Cap(this.label);
  final String label;

  bool test(ModelSpec s) => switch (this) {
    tools => s.tools,
    vision => s.imageInput,
    reasoning => s.reasoning,
    image => s.output == Modality.image,
  };
}

/// The model shop: every model the backend offers in one table (model, context, price per million tokens in · out,
/// Add), with a search, a scope, the biggest vendors and capability toggles. "Add" puts a model in My models, the
/// composer's picker list.
class ModelsScreen extends ConsumerStatefulWidget {
  const ModelsScreen({super.key});

  @override
  ConsumerState<ModelsScreen> createState() => _ModelsScreenState();
}

class _ModelsScreenState extends ConsumerState<ModelsScreen> {
  _Filter _filter = _Filter.all;
  ModelProvider? _provider;
  final _caps = <_Cap>{};
  String _query = '';

  /// Bumped when the filters change, so the rows enter again (staggered).
  int _generation = 0;

  void _refilter(VoidCallback change) => setState(() {
    change();
    _generation++;
  });

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final catalog = ref.watch(modelCatalogProvider);
    final library = ref.watch(libraryProvider).value ?? const <ModelSpec>[];
    final defaultModel = ref.watch(defaultModelProvider);
    final mine = {for (final s in library) s.id};
    final billing = ref.watch(modelBillingProvider);
    final q = _query.trim().toLowerCase();

    // Vendors with the most models first; the top few get a chip, the rest a menu.
    final providers = catalog.providers.toList()
      ..sort((a, b) => catalog.byProvider(b).length.compareTo(catalog.byProvider(a).length));
    final shown = providers.take(6).toList();
    final more = providers.skip(6).toList();

    final source = _filter == _Filter.mine ? library : catalog.all;
    final models = source
        .where(
          (s) =>
              _filter.test(s, mine, billing) &&
              _caps.every((c) => c.test(s)) &&
              (_provider == null || s.provider == _provider) &&
              (q.isEmpty ||
                  s.name.toLowerCase().contains(q) ||
                  s.id.value.toLowerCase().contains(q) ||
                  s.provider.company.toLowerCase().contains(q) ||
                  s.blurb.toLowerCase().contains(q)),
        )
        .toList(growable: false);

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(22, 4, 22, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: AdaptiveTextField(
                    key: const ValueKey('shop.search'),
                    placeholder: 'Search ${catalog.length} models',
                    prefix: AdaptiveIcon(EveryIcon.search, size: 14, color: theme.textSubtle),
                    onChanged: (v) => setState(() => _query = v),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              const Spacer(),
              Text('${library.length} in My models', style: theme.type.caption.tint(theme.textSubtle)),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 4,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final f in _Filter.values)
                if (f != _Filter.ownKey || billing.hasKeys)
                  KitChip(
                    key: ValueKey('shop.filter.${f.name}'),
                    label: f.label,
                    on: _filter == f,
                    onTap: () => _refilter(() => _filter = f),
                  ),
              const SizedBox(width: 10),
              for (final p in shown)
                KitChip(
                  key: ValueKey('shop.vendor.${p.company}'),
                  label: p.company,
                  on: _provider == p,
                  onTap: () => _refilter(() => _provider = _provider == p ? null : p),
                ),
              if (more.isNotEmpty)
                AdaptiveMenuButton(
                  width: 240,
                  actions: [
                    for (final p in more)
                      MenuAction(
                        label: p.company,
                        checked: _provider == p,
                        onSelected: () => _refilter(() => _provider = _provider == p ? null : p),
                      ),
                  ],
                  child: KitChip(
                    label: _provider != null && more.contains(_provider) ? _provider!.company : 'More',
                    on: _provider != null && more.contains(_provider),
                    chevron: true,
                  ),
                ),
              const SizedBox(width: 10),
              for (final c in _Cap.values)
                KitChip(
                  key: ValueKey('shop.cap.${c.name}'),
                  label: c.label,
                  on: _caps.contains(c),
                  leading: StateSwap(
                    child: AdaptiveIcon(
                      _caps.contains(c) ? EveryIcon.check : EveryIcon.add,
                      key: ValueKey(_caps.contains(c)),
                      size: 12,
                    ),
                  ),
                  onTap: () => _refilter(() => _caps.contains(c) ? _caps.remove(c) : _caps.add(c)),
                ),
            ],
          ),
          const SizedBox(height: 10),
          _Columns(
            model: Text('Model', style: theme.type.caption.tint(theme.textSubtle)),
            context: Text('Context', style: theme.type.caption.tint(theme.textSubtle)),
            price: Text('In · Out per M', style: theme.type.caption.tint(theme.textSubtle)),
            action: const SizedBox(),
            indentModel: true,
          ),
        ],
      ),
    );

    return AdaptivePage(
      title: 'Models',
      header: header,
      body: ListView.builder(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 32),
        itemCount: models.isEmpty ? 1 : models.length,
        itemBuilder: (context, i) {
          if (models.isEmpty) {
            final filtered = q.isNotEmpty || _provider != null || _filter != _Filter.all || _caps.isNotEmpty;
            return Padding(
              padding: const EdgeInsets.only(top: 48),
              child: Center(
                child: Text(
                  _filter == _Filter.mine && !filtered
                      ? 'No models yet'
                      : filtered
                      ? 'No models match'
                      : "The catalog couldn't be loaded",
                  style: theme.type.callout.tint(theme.textSubtle),
                ),
              ).settle(),
            );
          }
          final spec = models[i];
          final row = _ModelRow(
            key: ValueKey('shop.row.${spec.id.value}'),
            spec: spec,
            added: mine.contains(spec.id),
            isDefault: spec == defaultModel,
            // Free models cost nothing on EveryAI, so there is nothing to pick.
            billers: spec.free ? const [Biller.everyai] : billing.billersFor(spec.id),
            biller: spec.free ? Biller.everyai : billing.billerFor(spec.id),
            onToggle: () => ref.read(libraryProvider.notifier).toggle(spec),
            onAddBilledTo: (b) {
              ref.read(modelBillersProvider.notifier).set(spec.id, b);
              if (!mine.contains(spec.id)) ref.read(libraryProvider.notifier).toggle(spec);
            },
            onMakeDefault: () => ref.read(defaultModelProvider.notifier).set(spec),
          );
          // The first screenful enters staggered after a filter change.
          return i < 14 ? KeyedSubtree(key: ValueKey('g$_generation.$i'), child: row.rowIn(i)) : row;
        },
      ),
    );
  }
}

/// The table's columns: model (fills), context, price, action.
class _Columns extends StatelessWidget {
  const _Columns({
    required this.model,
    required this.context,
    required this.price,
    required this.action,
    this.indentModel = false,
  });

  final Widget model;
  final Widget context;
  final Widget price;
  final Widget action;

  /// The header's "Model" lines up with the names, after the marks.
  final bool indentModel;

  @override
  Widget build(BuildContext ctx) => LayoutBuilder(
    builder: (ctx, box) {
      final roomy = box.maxWidth > 560;
      // Narrow windows: the price goes under the model, and the action takes only its own width.
      final compact = box.maxWidth < 480;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(left: indentModel ? 38 : 0),
                child: compact
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          model,
                          Padding(
                            padding: EdgeInsets.only(left: indentModel ? 0 : 38),
                            child: price,
                          ),
                        ],
                      )
                    : model,
              ),
            ),
            if (roomy) ...[
              const SizedBox(width: 14),
              SizedBox(
                width: 70,
                child: Align(alignment: Alignment.centerRight, child: context),
              ),
            ],
            if (!compact) ...[
              const SizedBox(width: 14),
              SizedBox(
                width: 120,
                child: Align(alignment: Alignment.centerRight, child: price),
              ),
            ],
            const SizedBox(width: 10),
            if (compact)
              action
            else
              SizedBox(
                width: 124,
                // Large text scales the button down rather than pushing the columns apart.
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FittedBox(fit: BoxFit.scaleDown, child: action),
                ),
              ),
          ],
        ),
      );
    },
  );
}

class _ModelRow extends StatefulWidget {
  const _ModelRow({
    super.key,
    required this.spec,
    required this.added,
    required this.isDefault,
    required this.billers,
    required this.biller,
    required this.onToggle,
    required this.onAddBilledTo,
    required this.onMakeDefault,
  });

  final ModelSpec spec;
  final bool added;
  final bool isDefault;

  /// Who can pay for this model; more than one makes Add a menu.
  final List<Biller> billers;
  final Biller biller;
  final VoidCallback onToggle;

  /// Bills the model to the account and adds it (if it isn't already).
  final ValueChanged<Biller> onAddBilledTo;
  final VoidCallback onMakeDefault;

  @override
  State<_ModelRow> createState() => _ModelRowState();
}

class _ModelRowState extends State<_ModelRow> {
  bool _hover = false;

  /// Bumped on Add, so the button pulses once.
  int _added = 0;

  @override
  void didUpdateWidget(_ModelRow old) {
    super.didUpdateWidget(old);
    if (widget.added && !old.added) _added++;
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final spec = widget.spec;
    final tags = [
      if (spec.tools) 'Tools',
      if (spec.imageInput) 'Vision',
      if (spec.reasoning) 'Reasoning',
      if (spec.output == Modality.image) 'Makes images',
      if (widget.isDefault) 'Default for new chats',
      if (widget.biller.isOwnKey) 'Bills to your ${widget.biller.provider!.name} key',
    ].join(' · ');
    final choose = widget.billers.length > 1;
    final mono = theme.type.caption.mono;
    final add = choose && !widget.added
        ? AdaptiveMenuButton(
            key: ValueKey('shop.add.${spec.id.value}'),
            tooltip: 'Add and choose who pays',
            width: 260,
            actions: [
              for (final b in widget.billers)
                MenuAction(
                  label: 'Bill to ${b.label}',
                  checked: b == widget.biller,
                  onSelected: () => widget.onAddBilledTo(b),
                ),
            ],
            // The menu takes the tap; the button only shows it.
            child: const IgnorePointer(
              child: KitButton(label: 'Add…', onPressed: _noop),
            ),
          )
        : SuccessPulse(
            trigger: _added == 0 ? null : _added,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 84),
              child: KitButton(
                key: ValueKey('shop.toggle.${spec.id.value}'),
                label: widget.added ? 'Added' : 'Add',
                icon: widget.added ? EveryIcon.check : null,
                style: widget.added ? KitButtonStyle.soft : KitButtonStyle.primary,
                onPressed: widget.onToggle,
              ),
            ),
          );
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        constraints: const BoxConstraints(minHeight: 56),
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(color: _hover ? theme.hover : null, borderRadius: BorderRadius.circular(12)),
        child: _Columns(
          model: Row(
            children: [
              ModelAvatar(spec.provider, size: 24),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          flex: 3,
                          child: Text(
                            spec.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.type.body.medium.tint(theme.text),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            spec.provider.company,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.type.caption.tint(theme.textSubtle),
                          ),
                        ),
                      ],
                    ),
                    if (tags.isNotEmpty)
                      Text(
                        tags,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.type.caption.tint(theme.textSubtle),
                      ),
                  ],
                ),
              ),
            ],
          ),
          context: Text(spec.contextLength > 0 ? spec.contextLabel : '', style: mono.tint(theme.textMuted)),
          price: Text(spec.priceLabel ?? '', style: mono.tint(spec.free ? theme.success : theme.textMuted)),
          action: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedOpacity(
                opacity: _hover ? 1 : 0,
                duration: const Duration(milliseconds: 120),
                child: AdaptiveMenuButton(
                  tooltip: 'Model options',
                  actions: [
                    MenuAction(label: 'Use for new chats', checked: widget.isDefault, onSelected: widget.onMakeDefault),
                    MenuAction(
                      label: widget.added ? 'Remove from My models' : 'Add to My models',
                      onSelected: widget.onToggle,
                    ),
                    if (choose && widget.added)
                      for (final b in widget.billers)
                        MenuAction(
                          label: 'Bill to ${b.label}',
                          checked: b == widget.biller,
                          onSelected: () => widget.onAddBilledTo(b),
                        ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: AdaptiveIcon(EveryIcon.more, size: 15, color: theme.textMuted),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              add,
            ],
          ),
        ),
      ),
    );
  }
}

void _noop() {}
