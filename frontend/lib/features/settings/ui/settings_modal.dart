import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' as m;

import '../../../core/platform/platform_kind.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/anchored_popover.dart';
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
  try {
    await showGeneralDialog<void>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: true,
      barrierLabel: 'Close settings',
      barrierColor: const Color(0x66000000),
      transitionDuration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 180),
      transitionBuilder: (context, animation, _, child) => FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: ScaleTransition(
          scale: Tween(begin: 0.98, end: 1.0).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
          child: child,
        ),
      ),
      pageBuilder: (_, _, _) => const SettingsModal(),
    );
  } finally {
    container.read(settingsOpenProvider.notifier).set(false);
  }
}

/// Closes the Settings modal from inside a section (before navigating away).
void closeSettings(BuildContext context) => Navigator.of(context, rootNavigator: true).maybePop();

/// The Settings modal: search and the section list on the left, the section
/// on the right. Narrow windows show the list, then the section, with a back
/// control.
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
    final width = math.min(1100.0, box.maxWidth - 48);
    final height = math.min(760.0, box.maxHeight - 48);
    return Center(
      child: SizedBox(
        width: width,
        height: height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(EveryTheme.panelRadius),
            boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 60, offset: Offset(0, 30))],
          ),
          child: GlassSurface(
            level: GlassLevel.thick,
            radius: EveryTheme.panelRadius,
            child: _onMaterial(
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 12, 10),
                    child: Row(
                      children: [
                        Expanded(child: Text('Settings', style: theme.type.title.tint(theme.text))),
                        AdaptiveIconButton(
                          key: const ValueKey('settings.close'),
                          icon: EveryIcon.close,
                          tooltip: 'Close',
                          onPressed: _close,
                        ),
                      ],
                    ),
                  ),
                  Container(height: 1, color: theme.border),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(width: 240, child: _sidebar(theme)),
                        Container(width: 1, color: theme.border),
                        Expanded(child: _body(theme)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _narrow(EveryTheme theme) {
    final listing = _listing;
    return ColoredBox(
      color: theme.background,
      child: SafeArea(
        child: _onMaterial(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
                child: Row(
                  children: [
                    if (!listing)
                      AdaptiveIconButton(
                        key: const ValueKey('settings.back'),
                        icon: EveryIcon.chevronLeft,
                        tooltip: 'All settings',
                        onPressed: () => setState(() => _listing = true),
                      )
                    else
                      const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        listing ? 'Settings' : _section.title,
                        style: theme.type.headline.tint(theme.text),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    AdaptiveIconButton(
                      key: const ValueKey('settings.close'),
                      icon: EveryIcon.close,
                      tooltip: 'Close',
                      onPressed: _close,
                    ),
                  ],
                ),
              ),
              Container(height: 1, color: theme.border),
              Expanded(
                child: AnimatedSwitcher(
                  duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 180),
                  child: listing
                      ? KeyedSubtree(key: const ValueKey('settings.list'), child: _sidebar(theme))
                      : KeyedSubtree(key: ValueKey('settings.section.${_section.name}'), child: _sectionBody()),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Material list tiles and fields paint on the nearest Material: a
  /// transparent one over the glass (it draws nothing itself).
  static Widget _onMaterial(Widget child) => m.Material(type: m.MaterialType.transparency, child: child);

  /// The search field and the section list (or the search results).
  Widget _sidebar(EveryTheme theme) {
    final query = _query.text.trim();
    final results = query.isEmpty ? const <SettingsEntry>[] : searchSettings(query);
    final rows = <Widget>[];
    if (query.isEmpty) {
      SettingsGroup? group;
      for (final s in SettingsSection.values) {
        if (!s.available) continue;
        if (s.group != group) {
          group = s.group;
          if (group.label.isNotEmpty) rows.add(PopoverHeader(group.label));
          if (group == SettingsGroup.about) rows.add(const SizedBox(height: 10));
        }
        rows.add(
          _SectionRow(
            key: ValueKey('settings.nav.${s.name}'),
            section: s,
            selected: s == _section && (_wideLayout || !_listing),
            onTap: () => _open(s),
          ),
        );
      }
    } else if (results.isEmpty) {
      rows.add(
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text('No settings match "$query"', style: theme.type.callout.tint(theme.textMuted)),
        ),
      );
    } else {
      SettingsSection? section;
      for (final e in results) {
        if (e.section != section) {
          section = e.section;
          rows.add(PopoverHeader(section.title));
        }
        rows.add(
          PopoverRow(
            key: ValueKey('settings.result.${e.section.name}.${e.anchor ?? ''}'),
            title: e.title,
            onTap: () => _open(e.section, anchor: e.anchor),
          ),
        );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: AdaptiveTextField(
            key: const ValueKey('settings.search'),
            controller: _query,
            placeholder: 'Search settings',
            prefix: AdaptiveIcon(EveryIcon.search, size: 14, color: theme.textMuted),
            textInputAction: TextInputAction.search,
            onChanged: (_) => setState(() {}),
          ),
        ),
        Expanded(
          child: ListView(padding: const EdgeInsets.only(bottom: 12), children: rows),
        ),
      ],
    );
  }

  Widget _body(EveryTheme theme) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(28, 18, 28, 4),
        child: Text(_section.title, style: theme.type.title.tint(theme.text)),
      ),
      Expanded(child: _sectionBody()),
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

class _SectionRow extends StatefulWidget {
  const _SectionRow({super.key, required this.section, required this.selected, required this.onTap});

  final SettingsSection section;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SectionRow> createState() => _SectionRowState();
}

class _SectionRowState extends State<_SectionRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final on = widget.selected;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Semantics(
          button: true,
          selected: on,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: on
                  ? theme.accent.withValues(alpha: theme.isDark ? 0.22 : 0.14)
                  : _hover
                  ? theme.text.withValues(alpha: 0.06)
                  : null,
              borderRadius: BorderRadius.circular(theme.radius - 2),
            ),
            child: Row(
              children: [
                AdaptiveIcon(widget.section.icon, size: 16, color: on ? theme.accent : theme.textMuted),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.section.title,
                    style: (on ? theme.type.body.medium : theme.type.body).tint(theme.text),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A row search can jump to: scrolls itself into view and glows briefly when
/// the Settings target names it.
class SettingsAnchor extends ConsumerStatefulWidget {
  const SettingsAnchor({super.key, required this.section, required this.id, required this.child});

  final SettingsSection section;
  final String id;
  final Widget child;

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
