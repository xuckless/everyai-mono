import 'package:cupertino_ui/cupertino_ui.dart' as c;
import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart' as mac;
import 'package:material_ui/material_ui.dart' as m;

import '../../app/shell.dart';
import '../platform/platform_kind.dart';
import '../theme/every_theme.dart';
import 'adaptive.dart';
import 'every_icons.dart';

/// The leading space macos_ui's ToolBar reserves for the traffic lights, less
/// a normal content inset.
const _macTrafficLightInset = 62.0;

/// A top-level page with native chrome:
/// - Cupertino: translucent navigation bar that content scrolls beneath (glass)
/// - macOS: unified toolbar inside the window, sidebar toggle implied
/// - Fluent: page header with a command row, on Mica
/// - Material 3: top app bar; Adwaita: compact centered header bar
///
/// [body] should let its scroll views consume `MediaQuery.padding` (the default
/// for ListView), so content can slide under translucent bars.
class AdaptivePage extends StatelessWidget {
  const AdaptivePage({super.key, required this.title, this.titleWidget, this.actions = const [], required this.body});

  final String title;

  /// Replaces the plain title (the chat screen's model picker).
  final Widget? titleWidget;
  final List<Widget> actions;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final shell = ShellScope.of(context);
    final titleView = titleWidget ?? Text(title, overflow: TextOverflow.ellipsis);
    final sidebarButton = shell.showSidebarButton && theme.design != DesignLanguage.macos
        ? AdaptiveIconButton(icon: EveryIcon.menu, tooltip: 'Show sidebar', onPressed: shell.toggleSidebar)
        : null;

    switch (theme.design) {
      case DesignLanguage.cupertino:
        return c.CupertinoPageScaffold(
          backgroundColor: theme.background,
          navigationBar: c.CupertinoNavigationBar(
            leading: sidebarButton,
            middle: titleView,
            trailing: actions.isEmpty ? null : Row(mainAxisSize: MainAxisSize.min, children: actions),
            backgroundColor: theme.surface.withValues(alpha: 0.55),
            automaticBackgroundVisibility: false,
            enableBackgroundFilterBlur: true,
            border: Border(bottom: BorderSide(color: theme.border, width: 0)),
          ),
          child: body,
        );
      case DesignLanguage.macos:
        return mac.MacosScaffold(
          toolBar: mac.ToolBar(
            // ToolBar keeps 70pt free for the traffic lights unless macos_ui's
            // own sidebar is showing; ours draws its own, so pull the title
            // back to the content edge.
            title: Transform.translate(offset: const Offset(-_macTrafficLightInset, 0), child: titleView),
            titleWidth: 480,
            enableBlur: true,
            actions: [for (final a in actions) mac.CustomToolbarItem(inToolbarBuilder: (_) => a)],
          ),
          children: [mac.ContentArea(builder: (context, _) => body)],
        );
      case DesignLanguage.fluent:
        return f.ScaffoldPage(
          padding: EdgeInsets.zero,
          header: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: f.PageHeader(
              leading: sidebarButton == null
                  ? null
                  : Padding(padding: const EdgeInsets.only(right: 8), child: sidebarButton),
              title: DefaultTextStyle.merge(style: const TextStyle(fontSize: 20), child: titleView),
              commandBar: Row(mainAxisAlignment: MainAxisAlignment.end, children: actions),
            ),
          ),
          content: body,
        );
      case DesignLanguage.material || DesignLanguage.adwaita:
        return m.Scaffold(
          backgroundColor: theme.background,
          appBar: m.AppBar(
            automaticallyImplyLeading: false,
            leading: sidebarButton,
            title: titleView,
            actions: [...actions, const SizedBox(width: 8)],
          ),
          body: body,
        );
    }
  }
}
