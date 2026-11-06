import 'package:flutter/widgets.dart';

import '../../app/shell.dart';
import '../platform/platform_kind.dart';
import '../theme/every_theme.dart';
import 'kit.dart';
import 'every_icons.dart';

/// Gives the [AdaptivePage]s below a back control when they don't set their
/// own (Settings pages on narrow windows).
class PageBackScope extends InheritedWidget {
  const PageBackScope({super.key, required this.onBack, this.tooltip = 'Back', required super.child});

  final VoidCallback? onBack;
  final String tooltip;

  static PageBackScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<PageBackScope>();

  @override
  bool updateShouldNotify(PageBackScope old) => onBack != old.onBack || tooltip != old.tooltip;
}

/// A top-level page: a 52pt header (sidebar button when the sidebar is out of
/// view, back, title, actions) over the body, inside the shell's panel.
///
/// [body] starts below the bar on its own: no screen has to remember the bar's
/// height. A body whose scroll view consumes `MediaQuery.padding` (a ListView
/// does) may set [scrollsUnderBar] so its content slides under a translucent
/// bar; nothing else sees that padding.
class AdaptivePage extends StatelessWidget {
  const AdaptivePage({
    super.key,
    required this.title,
    this.titleWidget,
    this.actions = const [],
    this.onBack,
    this.backTooltip = 'Back',
    this.header,
    this.scrollsUnderBar = false,
    required Widget body,
  }) : _body = body; // ignore: prefer_initializing_formals

  final String title;

  /// Replaces the plain title (the chat screen's model picker).
  final Widget? titleWidget;
  final List<Widget> actions;

  /// Shows a back control before the title (settings pages opened from
  /// elsewhere, child sessions).
  final VoidCallback? onBack;
  final String backTooltip;

  /// Stays put below the bar while [body] scrolls (a search field, filters).
  /// The body then starts below it, not under the bar.
  final Widget? header;

  /// The body's own scroll view takes the bar's height as padding (a ListView
  /// with no padding of its own) and wants its content to slide under the bar.
  /// Off: the body starts below the bar.
  final bool scrollsUnderBar;
  final Widget _body;

  /// The page's content: [header] pinned below the bar, then the body. Under
  /// a translucent bar a header in a plain Column would sit beneath the bar.
  Widget get body {
    final top = header;
    if (top == null) {
      if (scrollsUnderBar) return _body;
      return Builder(
        builder: (context) {
          final inset = MediaQuery.paddingOf(context).top;
          if (inset == 0) return _body;
          return Padding(
            padding: EdgeInsets.only(top: inset),
            child: MediaQuery.removePadding(context: context, removeTop: true, child: _body),
          );
        },
      );
    }
    return LayoutBuilder(
      builder: (context, box) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
            // On a short window the header never takes more than half the height; past that it scrolls itself.
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: box.maxHeight.isFinite ? box.maxHeight / 2 : double.infinity),
              child: SingleChildScrollView(primary: false, child: top),
            ),
          ),
          Expanded(
            child: MediaQuery.removePadding(context: context, removeTop: true, child: _body),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final shell = ShellScope.maybeOf(context);
    final touch = shell?.compact ?? Host.isMobile;
    final titleView = DefaultTextStyle.merge(
      style: theme.type.headline.tint(theme.text),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      child: titleWidget ?? Text(title, overflow: TextOverflow.ellipsis, maxLines: 1),
    );
    final sidebarButton = shell != null && shell.showSidebarButton
        ? KitIconButton(
            icon: touch ? EveryIcon.menu : EveryIcon.sidebar,
            tooltip: 'Show sidebar',
            touch: touch,
            onPressed: shell.toggleSidebar,
          )
        : null;
    final scope = PageBackScope.maybeOf(context);
    final back = onBack ?? scope?.onBack;
    final backButton = back == null
        ? null
        : KitIconButton(
            icon: EveryIcon.chevronLeft,
            tooltip: onBack != null ? backTooltip : scope!.tooltip,
            touch: touch,
            onPressed: back,
          );
    final top = MediaQuery.paddingOf(context).top;
    // 18pt before a bare title, less before a button.
    final hasButton = sidebarButton != null || backButton != null;
    final left = (shell?.leadingInset ?? 0) + (hasButton ? (touch ? 4 : 8) : (touch ? 16 : 18));
    final bar = Padding(
      padding: EdgeInsets.only(top: top, left: left, right: touch ? 6 : 10),
      child: SizedBox(
        height: 52,
        child: Row(
          children: [
            ?sidebarButton,
            ?backButton,
            if (hasButton) const SizedBox(width: 4),
            Expanded(child: titleView),
            for (final a in actions) ...[const SizedBox(width: 2), a],
          ],
        ),
      ),
    );
    return ColoredBox(
      color: touch ? theme.background : const Color(0x00000000),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          bar,
          Expanded(
            child: MediaQuery.removePadding(context: context, removeTop: true, child: body),
          ),
        ],
      ),
    );
  }
}

/// Puts [child] below a translucent bar when it sits in a body that scrolls under one ([AdaptivePage.scrollsUnderBar]):
/// a side panel next to such a list. Nothing changes where the body already starts below the bar.
class BelowBar extends StatelessWidget {
  const BelowBar({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    if (top == 0) return child;
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: MediaQuery.removePadding(context: context, removeTop: true, child: child),
    );
  }
}
