// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../core/platform/platform_kind.dart';

// The macOS menu bar. There is one native menu, and Flutter lets one PlatformMenuBar hold it at a time: a second one
// mounting before the first is disposed asserts ("_lockedContext != context" in platform_menu_bar.dart). That
// happened whenever the bar's place in the tree changed, because the new element is built before the old one goes:
// the shell's server banner wrapping the page in a Stack, the onboarding gate, the shell itself remounting.
//
// So the bar is mounted once, at the app root above the router (see EveryApp), and nothing else may build one
// (test/app/app_menu_test.dart checks the sources). The shell only lends it actions through [AppMenuActions]; while
// no shell is up (onboarding, sign-in) the items are greyed out.

/// What the menu's items do, lent by the shell while it is mounted.
@immutable
final class ShellMenuActions {
  const ShellMenuActions({
    required this.openSettings,
    required this.newChat,
    required this.toggleSidebar,
    required this.openModels,
  });

  final VoidCallback openSettings;
  final VoidCallback newChat;
  final VoidCallback toggleSidebar;
  final VoidCallback openModels;
}

/// Who lends the menu its actions: at most one owner (the mounted shell).
///
///   none ──[lend] by a shell──▶ lent(owner) ──[release] by that owner──▶ none
///                                   └──[lend] by a newer shell──▶ lent(new owner) (the old one's release then does
///                                                                  nothing)
///
/// Listeners hear of a change in a microtask, never inside the build or teardown that caused it (a shell lends from
/// initState and releases from dispose, when the tree is locked).
final class AppMenuActions extends ChangeNotifier {
  AppMenuActions._();

  /// The app's one holder.
  static final instance = AppMenuActions._();

  Object? _owner;
  ShellMenuActions? _actions;
  var _notifyQueued = false;

  ShellMenuActions? get actions => _actions;

  void lend(Object owner, ShellMenuActions actions) {
    final changed = _owner != owner || _actions == null;
    _owner = owner;
    _actions = actions;
    if (changed) _notifySoon();
  }

  void release(Object owner) {
    if (_owner != owner) return;
    _owner = null;
    _actions = null;
    _notifySoon();
  }

  void _notifySoon() {
    if (_notifyQueued) return;
    _notifyQueued = true;
    scheduleMicrotask(() {
      _notifyQueued = false;
      notifyListeners();
    });
  }

  @visibleForTesting
  void reset() {
    _owner = null;
    _actions = null;
  }
}

/// Whether this host shows the app's menu in a native menu bar (macOS only).
bool get hasNativeMenuBar => Host.isApple && defaultTargetPlatform == TargetPlatform.macOS;

/// The app's one menu bar, around the whole app. Its place in the tree never changes: it is the root's outermost
/// widget on every host (elsewhere it only passes [child] through), so it mounts once for the app's life.
class AppMenuBar extends StatelessWidget {
  const AppMenuBar({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!hasNativeMenuBar) return child;
    return ListenableBuilder(
      listenable: AppMenuActions.instance,
      builder: (context, child) => PlatformMenuBar(menus: appMenus(AppMenuActions.instance.actions), child: child),
      child: child,
    );
  }
}

/// The menus, with [actions] or greyed out without them.
List<PlatformMenuItem> appMenus(ShellMenuActions? actions) {
  SingleActivator shortcut(LogicalKeyboardKey key, {bool shift = false}) =>
      SingleActivator(key, meta: true, shift: shift);
  return [
    PlatformMenu(
      label: 'EveryAI',
      menus: [
        const PlatformMenuItemGroup(members: [PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.about)]),
        PlatformMenuItemGroup(
          members: [
            PlatformMenuItem(
              label: 'Settings…',
              shortcut: shortcut(LogicalKeyboardKey.comma),
              onSelected: actions?.openSettings,
            ),
          ],
        ),
        const PlatformMenuItemGroup(
          members: [
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
          ],
        ),
      ],
    ),
    PlatformMenu(
      label: 'File',
      menus: [
        PlatformMenuItem(label: 'New Chat', shortcut: shortcut(LogicalKeyboardKey.keyN), onSelected: actions?.newChat),
      ],
    ),
    PlatformMenu(
      label: 'View',
      menus: [
        PlatformMenuItem(
          label: 'Toggle Sidebar',
          shortcut: shortcut(LogicalKeyboardKey.keyS, shift: true),
          onSelected: actions?.toggleSidebar,
        ),
        PlatformMenuItem(
          label: 'Models',
          shortcut: shortcut(LogicalKeyboardKey.keyM, shift: true),
          onSelected: actions?.openModels,
        ),
        const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.toggleFullScreen),
      ],
    ),
    const PlatformMenu(
      label: 'Window',
      menus: [
        PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.minimizeWindow),
        PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.zoomWindow),
      ],
    ),
  ];
}
