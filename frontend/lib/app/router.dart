import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../features/auth/auth_providers.dart';
import '../features/auth/domain/auth_state.dart';
import '../features/auth/ui/sign_in_screen.dart';
import '../core/ui/every_icons.dart';
import '../features/chat/ui/chat_screen.dart';
import '../features/history/ui/chats_screen.dart';
import '../features/history/ui/coming_soon_screen.dart';
import '../features/models/ui/models_screen.dart';
import '../features/settings/appearance.dart';
import '../features/billing/ui/billing_screen.dart';
import '../features/settings/ui/settings_screen.dart';
import 'shell.dart';

abstract final class Routes {
  static const signIn = '/sign-in';
  static const signUp = '/sign-up';
  static const models = '/models';
  static const settings = '/settings';
  static const billing = '/settings/billing';
  static const newChat = '/chat/new';
  static const chats = '/chats';
  static const projects = '/projects';
  static const artifacts = '/artifacts';
  static String chat(String id) => '/chat/$id';
}

/// Survives router rebuilds (switching design language swaps the app root and
/// therefore the router) so the user stays on the same screen.
String _lastLocation = const String.fromEnvironment('INITIAL_LOCATION', defaultValue: Routes.newChat);

final routerProvider = Provider<GoRouter>((ref) {
  // A new root widget per design language needs a fresh router.
  ref.watch(appearanceProvider.select((a) => a.design));

  final auth = ValueNotifier<AuthState>(ref.read(authProvider));
  ref.listen(authProvider, (_, next) => auth.value = next);

  final router = GoRouter(
    initialLocation: _lastLocation,
    refreshListenable: auth,
    redirect: (context, state) {
      final path = state.uri.path;
      final onAuthPage = path == Routes.signIn || path == Routes.signUp;
      switch (auth.value) {
        case Restoring():
          return null;
        case SignedOut() || Authenticating():
          return onAuthPage ? null : Routes.signIn;
        case SignedIn() || Bypassed():
          if (onAuthPage) return Routes.newChat;
          if (path == '/' || path == Routes.newChat) return Routes.chat(const Uuid().v7());
          return null;
      }
    },
    routes: [
      GoRoute(path: '/', redirect: (_, _) => Routes.newChat),
      GoRoute(
        path: Routes.signIn,
        builder: (_, _) => const SignInScreen(mode: AuthMode.signIn),
      ),
      GoRoute(
        path: Routes.signUp,
        builder: (_, _) => const SignInScreen(mode: AuthMode.signUp),
      ),
      ShellRoute(
        builder: (context, state, child) => AppShell(location: state.uri.path, child: child),
        routes: [
          GoRoute(
            path: '/chat/:id',
            pageBuilder: (_, state) => NoTransitionPage(
              key: ValueKey(state.pathParameters['id']),
              child: ChatScreen(conversationId: state.pathParameters['id']!),
            ),
          ),
          GoRoute(
            path: Routes.chats,
            pageBuilder: (_, _) => const NoTransitionPage(child: ChatsScreen()),
          ),
          GoRoute(
            path: Routes.projects,
            pageBuilder: (_, _) => const NoTransitionPage(
              child: ComingSoonScreen(
                title: 'Projects',
                icon: EveryIcon.projects,
                message: 'Group chats with shared files and instructions. Coming with the agentic tools.',
              ),
            ),
          ),
          GoRoute(
            path: Routes.artifacts,
            pageBuilder: (_, _) => const NoTransitionPage(
              child: ComingSoonScreen(
                title: 'Artifacts',
                icon: EveryIcon.artifacts,
                message: 'Documents, code and apps created in your chats will collect here.',
              ),
            ),
          ),
          GoRoute(
            path: Routes.models,
            pageBuilder: (_, _) => const NoTransitionPage(child: ModelsScreen()),
          ),
          GoRoute(
            path: Routes.settings,
            pageBuilder: (_, _) => const NoTransitionPage(child: SettingsScreen()),
          ),
          GoRoute(
            path: Routes.billing,
            pageBuilder: (_, _) => const NoTransitionPage(child: BillingScreen()),
          ),
        ],
      ),
    ],
  );
  void remember() => _lastLocation = router.routerDelegate.currentConfiguration.uri.toString();
  router.routerDelegate.addListener(remember);
  ref.onDispose(() {
    router.routerDelegate.removeListener(remember);
    router.dispose();
    auth.dispose();
  });
  return router;
});
