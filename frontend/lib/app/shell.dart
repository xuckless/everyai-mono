import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart' as m;

import 'package:app_links/app_links.dart';

import '../core/links/app_link.dart';
import '../core/motion/motion.dart';
import '../core/platform/window_caption.dart';
import '../core/links/link_providers.dart';
import '../core/platform/platform_kind.dart';
import '../core/net/api_client.dart' show ServerStatus;
import '../core/preferences.dart';
import '../core/providers.dart' show apiClientProvider, serverStatusProvider;
import '../features/auth/auth_providers.dart';
import '../features/updates/update_providers.dart' show updateProvider;
import '../features/updates/ui/whats_new_dialog.dart' show showWhatsNewOnce;
import '../core/theme/every_theme.dart';
import '../core/ui/adaptive.dart' show AdaptiveButton, AdaptiveProgress, GlassSurface, GlassLevel, showAdaptiveToast;
import '../features/code/automations/schedule_providers.dart' show scheduleRunnerProvider;
import '../features/code/code_providers.dart' show driverShutdownProvider, workflowResumeProvider;
import 'app_quit.dart' show appQuitProvider;
import '../features/code/forks/orphan_forks.dart' show orphanForksProvider;
import '../features/local_models/local_models_providers.dart' show serverLifecyclesProvider;
import '../features/local_models/local_model_bridge.dart' show localRoutesProvider, localUseTrackerProvider;
import '../features/code/drivers/driver_registry.dart' show driverStatusesProvider;
import '../features/code/ui/real_input_consent.dart' show connectRealInput;
import '../features/history/ui/sidebar.dart';
import '../features/code/board/board_plan_providers.dart' show boardPlanWatchProvider;
import '../features/onboarding/onboarding_providers.dart';
import '../features/onboarding/ui/onboarding_screen.dart';
import '../features/remote/remote_providers.dart' show remoteHostingProvider;
import '../features/settings/byok_keys.dart' show modelBillingProvider;
import '../features/settings/settings_registry.dart';
import '../features/settings/ui/settings_modal.dart';
import 'app_menu.dart';
import 'router.dart';

/// Lets pages toggle the sidebar and know whether it is showing.
class ShellScope extends InheritedWidget {
  const ShellScope({
    super.key,
    required this.sidebarVisible,
    required this.compact,
    required this.toggleSidebar,
    required super.child,
  });

  final bool sidebarVisible;
  final bool compact;
  final VoidCallback toggleSidebar;

  /// Pages show a sidebar button whenever the sidebar is out of view (a closed
  /// drawer on phones, a collapsed sidebar on wider windows).
  bool get showSidebarButton => !sidebarVisible || compact;

  /// Room a page header leaves on its left for the macOS traffic lights, which
  /// sit over the content panel once the sidebar is collapsed.
  double get leadingInset => Host.hasTrafficLights && !compact && !sidebarVisible ? 70 : 0;

  static ShellScope of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ShellScope>()!;

  /// Null outside the shell (tests, dialogs).
  static ShellScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ShellScope>();

  @override
  bool updateShouldNotify(ShellScope old) => sidebarVisible != old.sidebarVisible || compact != old.compact;
}

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  static const _collapsedKey = 'sidebar.collapsed';

  late bool _collapsed = ref.read(preferencesProvider)[_collapsedKey] == 'true'; // wide layouts
  bool _drawerOpen = false; // compact layouts

  void _toggle(bool compact) => setState(() {
    if (compact) {
      _drawerOpen = !_drawerOpen;
    } else {
      _collapsed = !_collapsed;
      ref.read(preferencesProvider)[_collapsedKey] = '$_collapsed';
    }
  });

  void _navigate(String location) {
    setState(() => _drawerOpen = false);
    context.go(location);
  }

  AppLifecycleListener? _lifecycle;
  StreamSubscription<Uri>? _links;

  /// A prompt link waiting for the page it opened: offered when the shell arrives at [route], dropped when the
  /// navigation lands anywhere else (a redirect), so an unrelated page never takes it later.
  ({PromptLink link, String route})? _awaitingLink;

  @override
  void didUpdateWidget(AppShell old) {
    super.didUpdateWidget(old);
    if (widget.location == old.location) return;
    if (_awaitingLink case (:final link, :final route)) {
      _awaitingLink = null;
      if (!landedOn(route, widget.location)) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(pendingPromptProvider.notifier).offer(link);
      });
    }
  }

  /// An `everyai://prompt` link: open the page whose box takes the text (it fills the box; nothing is sent).
  void _onLink(Uri uri) {
    switch (parseAppLink(uri)) {
      case final PromptLink link:
        final offered = linkForHost(link, desktop: Host.isDesktop);
        final to = routeForPrompt(offered, desktop: Host.isDesktop, chat: Routes.newChat, code: Routes.code);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (to == widget.location) {
            ref.read(pendingPromptProvider.notifier).offer(offered); // the page is already showing
          } else {
            // Offered once the new page is up: the page being left must not take it.
            _awaitingLink = (link: offered, route: to);
            context.go(to);
          }
        });
      case SignInLink():
        unawaited(ref.read(authProvider.notifier).pollNow());
      case OversizedLink():
        showAdaptiveToast(context, 'That link\'s text is too long.');
      case null:
        break;
    }
  }

  @override
  void initState() {
    super.initState();
    // The menu's items act on this shell once the entry screen is done (greyed out before, as during sign-in).
    ref.listenManual(onboardingAcceptedProvider, (_, accepted) {
      if (accepted) {
        AppMenuActions.instance.lend(
          this,
          ShellMenuActions(
            openSettings: _openSettings,
            newChat: () => _navigate(Routes.newChat),
            toggleSidebar: () => _toggle(WindowSize.of(context) == WindowSize.compact),
            openModels: () => _navigate(Routes.models),
          ),
        );
      } else {
        AppMenuActions.instance.release(this);
      }
    }, fireImmediately: true);
    if (!kIsWeb) {
      // Also delivers the link the app was started with.
      _links = AppLinks().uriLinkStream.listen(_onLink, onError: (Object _) {});
    }
    // A settings link that came before the shell existed (the first location).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ref.read(pendingSettingsProvider) != null) _openPendingSettings();
      // Which coding CLIs are installed: the last check at once, a new one in
      // the background, and again when the app comes back after a while.
      if (mounted && Host.isDesktop) ref.read(driverStatusesProvider);
      // Fork worktrees no session holds: the empty ones go now, the ones with work wait in Settings → Code.
      if (mounted && Host.isDesktop) ref.read(orphanForksProvider);
      // Workflow runs the app quit in the middle of carry on now, not when their session is next opened.
      if (mounted && Host.isDesktop) ref.read(workflowResumeProvider);
      // Updates: one check per launch (the controller waits a moment, and does nothing on dev or store installs).
      if (mounted && Host.isDesktop) ref.read(updateProvider);
      // After an update: this build's notes, once (never over the entry screen).
      if (mounted && ref.read(onboardingAcceptedProvider)) showWhatsNewOnce(context, ref);
    });
    if (Host.isDesktop) {
      // Agents driving app windows ask once before they use the real pointer and keyboard.
      connectRealInput(ref.read(preferencesProvider), () => context);
      _lifecycle = AppLifecycleListener(
        onResume: () => unawaited(ref.read(driverStatusesProvider.notifier).refreshIfStale()),
      );
    }
  }

  @override
  void dispose() {
    AppMenuActions.instance.release(this);
    _lifecycle?.dispose();
    unawaited(_links?.cancel());
    super.dispose();
  }

  void _openSettings() {
    setState(() => _drawerOpen = false);
    showSettings(context);
  }

  void _openPendingSettings() {
    final t = ref.read(pendingSettingsProvider.notifier).take();
    if (t == null || !mounted) return;
    setState(() => _drawerOpen = false);
    showSettings(context, section: t.section, anchor: t.anchor, args: t.args);
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final compact = WindowSize.of(context) == WindowSize.compact;
    // Loads the user's keys and billing picks for the request paths outside
    // Riverpod (the Code harness reads ModelBilling.current).
    ref.listen(modelBillingProvider, (_, _) {});
    // Hosting for remote devices runs app-wide (when the user turned it on);
    // a device asking to pair is announced wherever the user is.
    if (Host.isDesktop) {
      // Outside coding CLIs end with the app, whichever way they were started.
      ref.listen(driverShutdownProvider, (_, _) {});
      // The one quit sequence (sessions, browsers, devices, local servers, then every process left), and SIGTERM.
      ref.listen(appQuitProvider, (_, _) {});
      // Keeps LocalRoutes.current filled for the Code harness, which reads it per call.
      ref.listen(localRoutesProvider, (_, _) {});
      ref.listen(localUseTrackerProvider, (_, _) {});
      // Server phases (and Apple's server starting by itself) live as long as the app.
      ref.listen(serverLifecyclesProvider, (_, _) {});
      // Scheduled tasks start their sessions while the app is open.
      ref.listen(scheduleRunnerProvider, (_, _) {});
      // The Board's plans start the tasks waiting on finished ones, and races see their runners finish, wherever the
      // user is.
      ref.listen(boardPlanWatchProvider, (_, _) {});
      ref.listen(remoteHostingProvider.select((s) => s.link.pending.length), (before, now) {
        if (now > (before ?? 0)) {
          showAdaptiveToast(context, 'A device wants to use Code here. Approve it in Settings → Remote.');
        }
      });
    }
    // Old /settings links ask for the Settings modal; it opens over the page.
    ref.listen(pendingSettingsProvider, (_, next) {
      if (next != null) _openPendingSettings();
    });

    // The entry screen, once (updates keep it accepted), before anything else.
    if (!ref.watch(onboardingAcceptedProvider)) {
      return m.Material(
        color: theme.background,
        child: const WithWindowCaption(child: OnboardingScreen()),
      );
    }

    Widget body = ShellSplitView(
      compact: compact,
      collapsed: _collapsed,
      drawerOpen: _drawerOpen,
      onDismissDrawer: () => setState(() => _drawerOpen = false),
      sidebar: SafeArea(
        right: false,
        child: Sidebar(
          location: widget.location,
          compact: compact,
          onNavigate: _navigate,
          onToggle: () => _toggle(compact),
        ),
      ),
      content: widget.child,
    );
    body = ShellScope(
      sidebarVisible: compact ? _drawerOpen : !_collapsed,
      compact: compact,
      toggleSidebar: () => _toggle(compact),
      child: body,
    );

    final apple = Host.isApple;
    SingleActivator shortcut(LogicalKeyboardKey key, {bool shift = false}) =>
        SingleActivator(key, meta: apple, control: !apple, shift: shift);
    final shortcuts = <ShortcutActivator, VoidCallback>{
      shortcut(LogicalKeyboardKey.keyN): () => _navigate(Routes.newChat),
      shortcut(LogicalKeyboardKey.comma): _openSettings,
      shortcut(LogicalKeyboardKey.keyM, shift: true): () => _navigate(Routes.models),
      shortcut(LogicalKeyboardKey.keyS, shift: true): () => _toggle(compact),
    };
    body = CallbackShortcuts(
      bindings: shortcuts,
      child: Focus(autofocus: true, child: body),
    );

    // The macOS menu bar is the app root's (app_menu.dart); this shell only lends it its actions (initState).

    // A deployed backend may still be starting: say so instead of failing quietly.
    // The Stack is always there: wrapping the page only while the banner shows would rebuild the whole page
    // (and mount a second PlatformMenuBar before the old one lets go of the menu, which asserts).
    final server = ref.watch(serverStatusProvider).value;
    body = Stack(
      children: [
        body,
        if (server == ServerStatus.waking || server == ServerStatus.unreachable)
          Positioned(
            top: 12,
            left: 0,
            right: 0,
            child: Center(child: _ServerBanner(status: server!)),
          ),
      ],
    );

    // Material widgets need a Material ancestor for text editing.
    return m.Material(color: theme.background, child: body);
  }
}

/// "Waking up the EveryAI server…" while it starts; Retry when it didn't come up.
class _ServerBanner extends ConsumerWidget {
  const _ServerBanner({required this.status});

  final ServerStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final waking = status == ServerStatus.waking;
    return GlassSurface(
      level: GlassLevel.thick,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (waking) const SizedBox.square(dimension: 16, child: AdaptiveProgress()),
          if (waking) const SizedBox(width: 10),
          Text(
            waking ? 'Waking up the EveryAI server…' : "Can't reach the EveryAI server.",
            style: theme.type.callout.copyWith(color: theme.text),
          ),
          if (!waking) ...[
            const SizedBox(width: 10),
            AdaptiveButton(
              label: 'Retry',
              onPressed: () => ref.read(apiClientProvider).awaitOnline().catchError((Object _) {}),
            ),
          ],
        ],
      ),
    );
  }
}

/// Sidebar + content. Wide: the sidebar on the window background and the page
/// in an inset panel; collapsing slides the sidebar away (ease-in-out).
/// Compact: the page fills the window and the sidebar is a drawer over a scrim.
@visibleForTesting
class ShellSplitView extends StatelessWidget {
  const ShellSplitView({
    super.key,
    required this.compact,
    required this.collapsed,
    required this.drawerOpen,
    required this.onDismissDrawer,
    required this.sidebar,
    required this.content,
  });

  final bool compact;
  final bool collapsed;
  final bool drawerOpen;
  final VoidCallback onDismissDrawer;
  final Widget sidebar;
  final Widget content;

  static const sidebarWidth = 264.0;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final reduced = Motion.reduced(context);

    if (!compact) {
      final duration = reduced ? Duration.zero : Motion.move;
      final Widget wide = ColoredBox(
        color: theme.background,
        child: Row(
          children: [
            AnimatedContainer(
              duration: duration,
              curve: Motion.easeInOut,
              width: collapsed ? 0 : sidebarWidth,
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.centerRight,
                  minWidth: sidebarWidth,
                  maxWidth: sidebarWidth,
                  child: ExcludeFocus(excluding: collapsed, child: sidebar),
                ),
              ),
            ),
            Expanded(
              child: AnimatedPadding(
                duration: duration,
                curve: Motion.easeInOut,
                // Windows/Linux: the panel starts below the caption strip, so the window buttons and the drag area
                // get their own headroom instead of covering the panel's header.
                padding: EdgeInsets.fromLTRB(collapsed ? 8 : 0, hasCustomCaption ? windowCaptionHeight : 8, 8, 8),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.surface,
                    borderRadius: BorderRadius.circular(EveryTheme.panelRadius),
                    border: theme.hairline,
                  ),
                  child: ClipRRect(borderRadius: BorderRadius.circular(EveryTheme.panelRadius), child: content),
                ),
              ),
            ),
          ],
        ),
      );
      if (!hasCustomCaption) return wide;
      // Windows/Linux: the caption strip sits above the panel, on the window background, beside the sidebar.
      return Stack(
        children: [
          Positioned.fill(child: wide),
          Positioned(top: 0, right: 0, left: collapsed ? 0 : sidebarWidth, child: const WindowCaption()),
        ],
      );
    }

    final width = (MediaQuery.sizeOf(context).width * 0.85).clamp(0.0, 318.0);
    final duration = reduced ? Duration.zero : (drawerOpen ? Motion.sheetIn : Motion.sheetOut);
    final curve = drawerOpen ? Motion.easeOut : Motion.easeExit;
    return Stack(
      children: [
        Positioned.fill(
          child: ColoredBox(
            color: theme.background,
            child: hasCustomCaption
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const WindowCaption(),
                      Expanded(child: content),
                    ],
                  )
                : content,
          ),
        ),
        IgnorePointer(
          ignoring: !drawerOpen,
          child: GestureDetector(
            onTap: onDismissDrawer,
            child: AnimatedContainer(
              duration: duration,
              curve: curve,
              color: drawerOpen ? theme.scrim : theme.scrim.withValues(alpha: 0),
            ),
          ),
        ),
        AnimatedPositioned(
          duration: duration,
          curve: curve,
          top: 0,
          bottom: 0,
          left: drawerOpen ? 0 : -width - 24,
          width: width,
          child: GestureDetector(
            onHorizontalDragEnd: (d) {
              if ((d.primaryVelocity ?? 0) < -300) onDismissDrawer();
            },
            child: DecoratedBox(
              decoration: BoxDecoration(color: theme.surface, boxShadow: drawerOpen ? theme.shadowPop : null),
              child: ExcludeFocus(excluding: !drawerOpen, child: sidebar),
            ),
          ),
        ),
      ],
    );
  }
}

/// Whether navigating to [route] ended at [location]. A new chat is redirected to the chat it makes
/// (`/chat/new` → `/chat/<id>`), so any chat page counts for it; other routes must match by path.
@visibleForTesting
bool landedOn(String route, String location) {
  final want = Uri.parse(route).path, at = Uri.parse(location).path;
  if (want == Routes.newChat) return at.startsWith('/chat/') && at != Routes.newChat;
  return want == at;
}
