import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' as m;

import '../../../core/motion/motion.dart';
import '../../../core/platform/platform_kind.dart';
import '../../../core/platform/window_caption.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../settings_registry.dart';
import 'settings_sections.dart';

/// Wide windows get the centered modal; narrower ones a full-window
/// drill-down list.
const settingsModalBreakpoint = 760.0;

/// Opens Settings at [section] (and the row [anchor], highlighted), over
/// whatever is on screen. When Settings is already open it only jumps.
/// [args] go to the section (Code: `scope`, `project`, `session`).
Future<void> showSettings(
  BuildContext context, {
  SettingsSection section = SettingsSection.general,
  String? anchor,
  Map<String, String> args = const {},
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  container.read(settingsTargetProvider.notifier).go(section, anchor: anchor, args: args);
  if (container.read(settingsOpenProvider)) return;
  container.read(settingsOpenProvider.notifier).set(true);
  final still = Motion.reduced(context);
  try {
    await Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierDismissible: true,
        barrierLabel: 'Close settings',
        barrierColor: EveryTheme.of(context).scrim,
        // Ease-out in from 0.95; out 20% faster.
        transitionDuration: still ? Duration.zero : Motion.sheetIn,
        reverseTransitionDuration: still ? Duration.zero : Motion.sheetOut,
        transitionsBuilder: (context, animation, _, child) {
          final curve = CurvedAnimation(parent: animation, curve: Motion.easeOut, reverseCurve: Motion.easeExit);
          return FadeTransition(
            opacity: curve,
            child: ScaleTransition(scale: Tween(begin: 0.95, end: 1.0).animate(curve), child: child),
          );
        },
        pageBuilder: (_, _, _) => const SettingsModal(),
      ),
    );
  } finally {
    container.read(settingsOpenProvider.notifier).set(false);
  }
}

/// Closes the Settings modal from inside a section (before navigating away).
void closeSettings(BuildContext context) => Navigator.of(context, rootNavigator: true).maybePop();

/// The Settings modal: search and the section list on the left (one highlight slides between rows), the section
/// with its title and Close on the right. Narrow windows (phones) show grouped cards of sections, then the
/// section, which slides in with a back control.
class SettingsModal extends ConsumerStatefulWidget {
  const SettingsModal({super.key});

  @override
  ConsumerState<SettingsModal> createState() => _SettingsModalState();
}

class _SettingsModalState extends ConsumerState<SettingsModal> {
  final _query = TextEditingController();
  late SettingsSection _section;
  Map<String, String> _args = const {};

  /// Narrow layout: the list is showing instead of [_section].
  bool _listing = false;

  /// The last layout was the wide modal (the list then always sits beside the section).
  bool _wideLayout = true;

  @override
  void initState() {
    super.initState();
    final t = ref.read(settingsTargetProvider);
    _section = t?.section ?? SettingsSection.general;
    _args = t?.args ?? const {};
    if (!_section.available) _section = SettingsSection.general;
    // On narrow windows plain "Settings" starts at the list.
    _listing = t == null || (t.section == SettingsSection.general && t.anchor == null);
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _open(SettingsSection section, {String? anchor}) =>
      ref.read(settingsTargetProvider.notifier).go(section, anchor: anchor);

  void _close() => Navigator.of(context).maybePop();

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    ref.listen(settingsTargetProvider, (_, next) {
      if (next == null || !next.section.available) return;
      setState(() {
        _section = next.section;
        _args = next.args;
        _listing = false;
      });
    });
    Widget content = LayoutBuilder(
      builder: (context, box) {
        _wideLayout = box.maxWidth >= settingsModalBreakpoint;
        return _wideLayout ? _wide(theme, box) : _narrow(theme);
      },
    );
    content = DefaultTextStyle(style: theme.type.body.tint(theme.text), child: content);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _close,
        SingleActivator(LogicalKeyboardKey.keyW, meta: Host.isApple, control: !Host.isApple): _close,
      },
      child: FocusScope(autofocus: true, child: content),
    );
  }

  Widget _wide(EveryTheme theme, BoxConstraints box) {
    final width = math.min(980.0, box.maxWidth - 48);
    final height = math.min(680.0, box.maxHeight - 48);
    const radius = BorderRadius.all(Radius.circular(18));
    return Center(
      child: SizedBox(
        width: width,
        height: height,
        child: DecoratedBox(
          decoration: BoxDecoration(color: theme.surface, borderRadius: radius, boxShadow: theme.shadowPop),
          child: DecoratedBox(
            // The hairline paints over the content, so the sidebar's own fill doesn't hide it.
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: theme.border),
            ),
            child: ClipRRect(
              borderRadius: radius,
              child: _onMaterial(
                Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: 232,
                      child: ColoredBox(color: theme.background, child: _sidebar(theme)),
                    ),
                    Expanded(child: _body(theme)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _narrow(EveryTheme theme) {
    final listing = _listing;
    final reduced = Motion.reduced(context);
    return ColoredBox(
      color: theme.background,
      child: SafeArea(
        child: _onMaterial(
          WithWindowCaption(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 52,
                  child: Row(
                    children: [
                      const SizedBox(width: 4),
                      SizedBox(
                        width: 44,
                        child: listing
                            ? null
                            : KitIconButton(
                                key: const ValueKey('settings.back'),
                                icon: EveryIcon.chevronLeft,
                                tooltip: 'All settings',
                                touch: true,
                                onPressed: () => setState(() => _listing = true),
                              ),
                      ),
                      Expanded(
                        child: StateSwap(
                          alignment: Alignment.center,
                          child: Text(
                            listing ? 'Settings' : _section.title,
                            key: ValueKey(listing ? 'list' : _section.name),
                            textAlign: TextAlign.center,
                            style: theme.type.headline.tint(theme.text),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 44,
                        child: KitIconButton(
                          key: const ValueKey('settings.close'),
                          icon: EveryIcon.close,
                          tooltip: 'Close',
                          touch: true,
                          onPressed: _close,
                        ),
                      ),
                      const SizedBox(width: 4),
                    ],
                  ),
                ),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: reduced ? Duration.zero : Motion.move,
                    reverseDuration: reduced ? Duration.zero : Motion.exitOf(Motion.move),
                    switchInCurve: Motion.easeInOut,
                    switchOutCurve: Motion.easeInOut,
                    // A section comes in from the right; the list comes back from the left.
                    transitionBuilder: (child, animation) {
                      final isList = child.key == const ValueKey('settings.list');
                      final from = Offset(isList ? -0.25 : 0.25, 0);
                      return FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween(begin: from, end: Offset.zero).animate(animation),
                          child: child,
                        ),
                      );
                    },
                    child: listing
                        ? KeyedSubtree(key: const ValueKey('settings.list'), child: _phoneList(theme))
                        : KeyedSubtree(key: ValueKey('settings.section.${_section.name}'), child: _sectionBody()),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Material list tiles and fields paint on the nearest Material: a transparent one (it draws nothing itself).
  static Widget _onMaterial(Widget child) => m.Material(type: m.MaterialType.transparency, child: child);

  /// Phones: a search field, then the sections as grouped cards.
  Widget _phoneList(EveryTheme theme) {
    final query = _query.text.trim();
    final groups = <SettingsGroup, List<SettingsSection>>{};
    for (final s in SettingsSection.values) {
      if (s.available) (groups[s.group] ??= []).add(s);
    }
    var i = 0;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      children: [
        Padding(padding: const EdgeInsets.only(bottom: 16), child: _searchField(theme)),
        if (query.isNotEmpty)
          ..._results(theme, query)
        else
          for (final MapEntry(key: group, value: sections) in groups.entries)
            KitGroup(
              label: group.label,
              children: [
                for (final s in sections)
                  MenuRow(
                    key: ValueKey('settings.nav.${s.name}'),
                    touch: true,
                    leading: AdaptiveIcon(s.icon, size: 17, color: theme.textMuted),
                    trailing: AdaptiveIcon(EveryIcon.chevronRight, size: 14, color: theme.textSubtle),
                    onTap: () => _open(s),
                    child: Text(s.title),
                  ).rowIn(i++),
              ],
            ),
      ],
    );
  }

  Widget _searchField(EveryTheme theme) => AdaptiveTextField(
    key: const ValueKey('settings.search'),
    controller: _query,
    placeholder: 'Search',
    prefix: AdaptiveIcon(EveryIcon.search, size: 14, color: theme.textSubtle),
    textInputAction: TextInputAction.search,
    onChanged: (_) => setState(() {}),
  );

  /// Search results, grouped under their section.
  List<Widget> _results(EveryTheme theme, String query) {
    final results = searchSettings(query);
    if (results.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text('Nothing matches "$query"', style: theme.type.callout.tint(theme.textSubtle)),
        ),
      ];
    }
    final rows = <Widget>[];
    SettingsSection? section;
    for (final e in results) {
      if (e.section != section) {
        section = e.section;
        rows.add(KitLabel(section.title, padding: const EdgeInsets.fromLTRB(10, 12, 10, 4)));
      }
      rows.add(
        MenuRow(
          key: ValueKey('settings.result.${e.section.name}.${e.anchor ?? ''}'),
          onTap: () => _open(e.section, anchor: e.anchor),
          child: Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      );
    }
    return rows;
  }

  /// Desktop: the search field and the section list (or the search results), with one highlight that slides to
  /// the open section.
  Widget _sidebar(EveryTheme theme) {
    final query = _query.text.trim();
    final rows = <Widget>[];
    if (query.isEmpty) {
      final groups = <SettingsGroup, List<SettingsSection>>{};
      for (final s in SettingsSection.values) {
        if (s.available) (groups[s.group] ??= []).add(s);
      }
      final collapsed = ref.watch(settingsCollapsedGroupsProvider);
      for (final MapEntry(key: group, value: sections) in groups.entries) {
        final open = group.label.isEmpty || !collapsed.contains(group);
        if (group.label.isEmpty) {
          rows.add(const SizedBox(height: 14));
        } else {
          rows.add(
            _GroupHeader(
              key: ValueKey('settings.group.${group.name}'),
              label: group.label,
              open: open,
              onTap: () => ref.read(settingsCollapsedGroupsProvider.notifier).toggle(group),
            ),
          );
        }
        rows.add(
          AnimatedSize(
            duration: Motion.reduced(context) ? Duration.zero : Motion.move,
            curve: Motion.easeInOut,
            alignment: Alignment.topCenter,
            child: open
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final s in sections)
                        _SectionRow(
                          key: ValueKey('settings.nav.${s.name}'),
                          section: s,
                          selected: s == _section,
                          onTap: () => _open(s),
                        ),
                    ],
                  )
                : const SizedBox(width: double.infinity),
          ),
        );
      }
    } else {
      rows.addAll(_results(theme, query));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(padding: const EdgeInsets.fromLTRB(10, 14, 10, 4), child: _searchField(theme)),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 14),
            children: [
              if (query.isEmpty)
                _SlidingSelection(
                  selected: _section,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
                )
              else
                ...rows,
            ],
          ),
        ),
      ],
    );
  }

  Widget _body(EveryTheme theme) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SizedBox(
        height: 56,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 0, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: StateSwap(
                  child: Text(_section.title, key: ValueKey(_section.name), style: theme.type.title.tint(theme.text)),
                ),
              ),
              KitIconButton(
                key: const ValueKey('settings.close'),
                icon: EveryIcon.close,
                tooltip: 'Close',
                onPressed: _close,
              ),
            ],
          ),
        ),
      ),
      Expanded(
        child: StateSwap(
          child: KeyedSubtree(key: ValueKey('settings.pane.${_section.name}'), child: _sectionBody()),
        ),
      ),
    ],
  );

  Widget _sectionBody() => MediaQuery.removePadding(
    context: context,
    removeTop: true,
    removeBottom: true,
    removeLeft: true,
    removeRight: true,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: KeyedSubtree(
        key: ValueKey('settings.body.${_section.name}.${_args.entries.map((e) => '${e.key}=${e.value}').join('&')}'),
        child: settingsSectionBody(_section, _args),
      ),
    ),
  );
}

/// Draws one highlight behind the selected section row and slides it (ease-in-out) when the selection moves: the
/// same element travels, rows never paint their own.
class _SlidingSelection extends StatefulWidget {
  const _SlidingSelection({required this.selected, required this.child});

  final SettingsSection selected;
  final Widget child;

  @override
  State<_SlidingSelection> createState() => _SlidingSelectionState();
}

class _SlidingSelectionState extends State<_SlidingSelection> {
  final _stack = GlobalKey();
  Rect? _rect;
  bool _first = true;
  SettingsSection? _measured;

  void _measure() {
    if (!mounted) return;
    final stack = _stack.currentContext?.findRenderObject() as RenderBox?;
    RenderBox? row;
    void find(Element e) {
      if (row != null) return;
      if (e.widget.key == ValueKey('settings.nav.${widget.selected.name}')) {
        row = e.findRenderObject() as RenderBox?;
        return;
      }
      e.visitChildElements(find);
    }

    (_stack.currentContext as Element?)?.visitChildElements(find);
    if (stack == null) return;
    if (row == null || !row!.hasSize) {
      // The open section's group is collapsed: no highlight.
      if (_rect != null) setState(() => _rect = null);
      return;
    }
    final at = row!.localToGlobal(Offset.zero, ancestor: stack);
    final rect = at & row!.size;
    if (rect != _rect) {
      setState(() {
        // Slide only when the selection moved; a group opening or closing above just carries it along.
        _first = _rect == null || _measured == widget.selected;
        _measured = widget.selected;
        _rect = rect;
      });
      // A group may still be opening or closing: follow it until the row settles.
      WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    return Stack(
      key: _stack,
      children: [
        if (_rect case final r?)
          AnimatedPositioned(
            duration: _first || Motion.reduced(context) ? Duration.zero : Motion.move,
            curve: Motion.easeInOut,
            left: r.left,
            top: r.top,
            width: r.width,
            height: r.height,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.pressed,
                borderRadius: BorderRadius.circular(EveryTheme.rowRadius),
              ),
            ),
          ),
        widget.child,
      ],
    );
  }
}

class _SectionRow extends StatelessWidget {
  const _SectionRow({super.key, required this.section, required this.selected, required this.onTap});

  final SettingsSection section;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Pressable(
      onTap: onTap,
      selected: selected,
      semanticLabel: section.title,
      builder: (context, s, child) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: s.hovered && !selected ? theme.hover : null,
          borderRadius: BorderRadius.circular(EveryTheme.rowRadius),
        ),
        alignment: Alignment.centerLeft,
        child: child,
      ),
      child: AnimatedDefaultTextStyle(
        duration: Motion.swap,
        style: theme.type.callout.tint(selected ? theme.text : theme.textMuted),
        child: Text(section.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

/// A row search can jump to: scrolls itself into view and glows briefly when
/// the Settings target names it.
class SettingsAnchor extends ConsumerStatefulWidget implements KitRowLike {
  const SettingsAnchor({super.key, required this.section, required this.id, required this.child});

  final SettingsSection section;
  final String id;
  final Widget child;

  @override
  bool get groupsInCard => kitIsRow(child);

  @override
  ConsumerState<SettingsAnchor> createState() => _SettingsAnchorState();
}

class _SettingsAnchorState extends ConsumerState<SettingsAnchor> {
  bool _lit = false;
  Timer? _fade;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check(ref.read(settingsTargetProvider)));
  }

  @override
  void dispose() {
    _fade?.cancel();
    super.dispose();
  }

  void _check(SettingsTarget? t) {
    if (!mounted || t == null || t.section != widget.section || t.anchor != widget.id) return;
    final seq = t.seq;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final reduce = MediaQuery.disableAnimationsOf(context);
      unawaited(
        Scrollable.ensureVisible(
          context,
          alignment: 0.15,
          duration: reduce ? Duration.zero : const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        ),
      );
      ref.read(settingsTargetProvider.notifier).reached(seq);
      setState(() => _lit = true);
      _fade?.cancel();
      _fade = Timer(const Duration(milliseconds: 1600), () {
        if (mounted) setState(() => _lit = false);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    ref.listen(settingsTargetProvider, (_, next) => _check(next));
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      decoration: BoxDecoration(
        color: _lit ? theme.accent.withValues(alpha: theme.isDark ? 0.22 : 0.14) : const Color(0x00000000),
        borderRadius: BorderRadius.circular(theme.radius),
      ),
      child: widget.child,
    );
  }
}

/// A group heading in the Settings list: its label over a fine rule, and a chevron that folds the group away.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({super.key, required this.label, required this.open, required this.onTap});

  final String label;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Pressable(
      onTap: onTap,
      semanticLabel: '$label, ${open ? 'collapse' : 'expand'}',
      builder: (context, s, child) => Container(
        margin: const EdgeInsets.fromLTRB(0, 14, 0, 4),
        padding: const EdgeInsets.fromLTRB(10, 0, 6, 6),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: theme.border)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(label, style: theme.type.caption.medium.tint(s.hovered ? theme.textMuted : theme.textSubtle)),
            ),
            AnimatedRotation(
              turns: open ? 0 : -0.25,
              duration: Motion.reduced(context) ? Duration.zero : Motion.swap,
              curve: Motion.easeInOut,
              child: AdaptiveIcon(
                EveryIcon.chevronDown,
                size: 13,
                color: s.hovered ? theme.textMuted : theme.textSubtle,
              ),
            ),
          ],
        ),
      ),
      child: const SizedBox.shrink(),
    );
  }
}
