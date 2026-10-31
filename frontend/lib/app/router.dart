import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../features/artifacts/ui/artifacts_screen.dart';
import '../features/auth/auth_providers.dart';
import '../features/auth/domain/auth_state.dart';
import '../features/auth/ui/sign_in_screen.dart';
import '../features/chat/ui/chat_screen.dart';
import '../features/code/ui/code_home.dart';
import '../features/code/ui/session_view.dart';
import '../features/history/ui/chats_screen.dart';
import '../features/history/ui/projects_screen.dart';
import '../features/models/ui/models_screen.dart';
import '../features/settings/appearance.dart';
import '../features/settings/settings_registry.dart';
import '../core/platform/platform_kind.dart';
import '../features/remote/ui/remote_code.dart';
import 'shell.dart';

abstract final class Routes {
  static const signIn = '/sign-in';
  static const signUp = '/sign-up';
  static const models = '/models';

  /// Old Settings pages: each opens the Settings modal (see
  /// [settingsTargetForLocation]); use `showSettings` in new code.
  static const settings = '/settings';
  static const billing = '/settings/billing';
  static const usage = '/settings/usage';
  static const memory = '/settings/memory';
  static const commands = '/settings/commands';
  static const mcpServers = '/settings/mcp';
  static const skills = '/settings/skills';
  static const agents = '/settings/agents';
  static const notices = '/settings/notices';
  static const remote = '/settings/remote';
  static const newChat = '/chat/new';
  static const chats = '/chats';
  static const projects = '/projects';
  static const artifacts = '/artifacts';
  static const code = '/code';
  static String chat(String id) => '/chat/$id';
  static String codeSession(String id) => '/code/s/$id';
  static const codeSettingsPath = '/code/settings';
}

/// Asks the shell to open Settings at what [uri] stands for (after this
/// frame: the router is mid-build) and returns where the user was.
String _openSettings(Ref ref, Uri uri) {
  final target = settingsTargetForLocation(uri);
  if (target != null) {
    WidgetsBinding.instance.addPostFrameCallback((_) => ref.read(pendingSettingsProvider.notifier).request(target));
  }
  final back = _lastLocation;
  return settingsTargetForLocation(Uri.parse(back)) == null ? back : Routes.newChat;
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
      // Settings is a modal now: its old pages stay where the user was and
      // open the modal at the matching section.
      GoRoute(path: Routes.settings, redirect: (_, state) => _openSettings(ref, state.uri)),
      GoRoute(path: '${Routes.settings}/:section', redirect: (_, state) => _openSettings(ref, state.uri)),
      GoRoute(path: Routes.codeSettingsPath, redirect: (_, state) => _openSettings(ref, state.uri)),
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
            pageBuilder: (_, _) => const NoTransitionPage(child: ProjectsScreen()),
          ),
          GoRoute(
            path: Routes.artifacts,
            pageBuilder: (_, _) => const NoTransitionPage(child: ArtifactsScreen()),
          ),
          GoRoute(
            path: Routes.code,
            // Phones, tablets and the web follow a paired computer's sessions.
            pageBuilder: (_, _) => NoTransitionPage(child: Host.isDesktop ? const CodeHome() : const RemoteCodeHome()),
          ),
          GoRoute(
            path: '/code/s/:id',
            pageBuilder: (_, state) => NoTransitionPage(
              key: ValueKey('code-${state.pathParameters['id']}'),
              child: Host.isDesktop
                  ? CodeSessionScreen(sessionId: state.pathParameters['id']!)
                  : RemoteSessionScreen(sessionId: state.pathParameters['id']!),
            ),
          ),
          GoRoute(
            path: Routes.models,
            pageBuilder: (_, _) => const NoTransitionPage(child: ModelsScreen()),
          ),
        ],
      ),
    ],
  );
  void remember() {
    final now = router.routerDelegate.currentConfiguration.uri.toString();
    if (settingsTargetForLocation(Uri.parse(now)) == null) _lastLocation = now;
  }

  router.routerDelegate.addListener(remember);
  ref.onDispose(() {
    router.routerDelegate.removeListener(remember);
    router.dispose();
    auth.dispose();
  });
  return router;
});
