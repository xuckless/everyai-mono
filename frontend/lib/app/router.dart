import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../features/artifacts/ui/artifacts_screen.dart';
import '../features/auth/auth_providers.dart';
import '../features/auth/domain/auth_state.dart';
import '../features/auth/ui/sign_in_screen.dart';
import '../core/ui/every_icons.dart';
import '../features/chat/ui/chat_screen.dart';
import '../features/code/ui/code_home.dart';
import '../features/code/ui/code_settings_screen.dart';
import '../features/code/code_settings_providers.dart' show SettingsScope;
import '../features/code/ui/mcp_settings_screen.dart';
import '../features/code/ui/session_view.dart';
import '../features/history/ui/chats_screen.dart';
import '../features/history/ui/coming_soon_screen.dart';
import '../features/models/ui/models_screen.dart';
import '../features/settings/appearance.dart';
import '../features/billing/ui/billing_screen.dart';
import '../features/agents/ui/agents_settings_screen.dart';
import '../features/memory/ui/memory_screen.dart';
import '../features/slash/custom/custom_commands_screen.dart';
import '../features/remote/ui/remote_settings_screen.dart';
import '../features/settings/ui/notices_screen.dart';
import '../features/settings/ui/settings_screen.dart';
import '../features/skills/ui/skills_settings_screen.dart';
import '../features/usage/ui/usage_screen.dart';
import 'shell.dart';

abstract final class Routes {
  static const signIn = '/sign-in';
  static const signUp = '/sign-up';
  static const models = '/models';
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

  /// Code settings at [scope] (global, project, session) and [tab] (prompt,
  /// json, effective).
  static String codeSettings({String? projectId, String? sessionId, String? scope, String? tab}) => Uri(
    path: codeSettingsPath,
    queryParameters: {'project': ?projectId, 'session': ?sessionId, 'scope': ?scope, 'tab': ?tab},
  ).toString();
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
            pageBuilder: (_, _) => const NoTransitionPage(child: ArtifactsScreen()),
          ),
          GoRoute(
            path: Routes.code,
            pageBuilder: (_, _) => const NoTransitionPage(child: CodeHome()),
          ),
          GoRoute(
            path: Routes.codeSettingsPath,
            pageBuilder: (_, state) {
              final q = state.uri.queryParameters;
              return NoTransitionPage(
                key: ValueKey('code-settings-${state.uri.query}'),
                child: CodeSettingsScreen(
                  projectId: q['project'],
                  sessionId: q['session'],
                  scope: SettingsScope.parse(q['scope']),
                  tab: CodeSettingsTab.parse(q['tab']),
                ),
              );
            },
          ),
          GoRoute(
            path: '/code/s/:id',
            pageBuilder: (_, state) => NoTransitionPage(
              key: ValueKey('code-${state.pathParameters['id']}'),
              child: CodeSessionScreen(sessionId: state.pathParameters['id']!),
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
          GoRoute(
            path: Routes.usage,
            pageBuilder: (_, _) => const NoTransitionPage(child: UsageScreen()),
          ),
          GoRoute(
            path: Routes.mcpServers,
            pageBuilder: (_, _) => const NoTransitionPage(child: McpSettingsScreen()),
          ),
          GoRoute(
            path: Routes.skills,
            pageBuilder: (_, _) => const NoTransitionPage(child: SkillsSettingsScreen()),
          ),
          GoRoute(
            path: Routes.remote,
            pageBuilder: (_, _) => const NoTransitionPage(child: RemoteSettingsScreen()),
          ),
          GoRoute(
            path: Routes.notices,
            pageBuilder: (_, _) => const NoTransitionPage(child: NoticesScreen()),
          ),
          GoRoute(
            path: Routes.agents,
            pageBuilder: (_, _) => const NoTransitionPage(child: AgentsSettingsScreen()),
          ),
          GoRoute(
            path: Routes.memory,
            pageBuilder: (_, _) => const NoTransitionPage(child: MemoryScreen()),
          ),
          GoRoute(
            path: Routes.commands,
            pageBuilder: (_, _) => const NoTransitionPage(child: CustomCommandsScreen()),
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
