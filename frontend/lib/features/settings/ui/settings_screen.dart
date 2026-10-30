import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';

import '../../../core/platform/platform_kind.dart';
import '../../../core/providers.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/adaptive_page.dart';
import '../../auth/auth_providers.dart';
import '../../auth/domain/auth_state.dart';
import '../../code/mcp_providers.dart';
import '../../memory/memory_providers.dart';
import '../../models/models_providers.dart';
import '../appearance.dart';
import '../dev_upstream.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final appearance = ref.watch(appearanceProvider);
    final appearanceCtl = ref.read(appearanceProvider.notifier);
    final defaultModel = ref.watch(defaultModelProvider);
    final library = ref.watch(libraryProvider).value ?? const [];
    final auth = ref.watch(authProvider);
    final config = ref.watch(appConfigProvider);

    Widget picker<T>(String current, List<(String, T)> options, ValueChanged<T> onPick) => AdaptiveMenuButton(
      actions: [
        for (final (label, value) in options)
          MenuAction(label: label, checked: label == current, onSelected: () => onPick(value)),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          current,
          style: TextStyle(color: theme.accent, fontWeight: FontWeight.w600),
        ),
      ),
    );

    return AdaptivePage(
      title: 'Settings',
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 8, 16, 32),
        children: [
          const AdaptiveSectionHeader('Appearance'),
          AdaptiveListTile(
            title: const Text('Theme'),
            trailing: picker(appearance.theme.label, [
              for (final t in ThemePreference.values) (t.label, t),
            ], appearanceCtl.setTheme),
          ),
          AdaptiveListTile(
            title: const Text('Design'),
            subtitle: Text('Follows this device by default (${DesignLanguage.host.label}).'),
            trailing: picker<DesignLanguage?>(appearance.designOverride?.label ?? 'Automatic', [
              ('Automatic', null),
              for (final d in DesignLanguage.values) (d.label, d),
            ], appearanceCtl.setDesign),
          ),
          const AdaptiveSectionHeader('Chat'),
          AdaptiveListTile(
            title: const Text('Default model'),
            trailing: picker(defaultModel.name, [
              for (final s in {...library, defaultModel}) (s.name, s),
            ], ref.read(defaultModelProvider.notifier).set),
          ),
          AdaptiveListTile(
            title: const Text('Model shop'),
            subtitle: Text('${library.length} models in My models'),
            onTap: () => context.go(Routes.models),
          ),
          AdaptiveListTile(
            title: const Text('Memory'),
            subtitle: Text(
              ref.watch(memoryProvider.select((m) => m.enabled))
                  ? 'On. Notes about you and search over your chats, kept on this device'
                  : 'Off',
            ),
            onTap: () => context.go(Routes.memory),
          ),
          AdaptiveListTile(
            title: const Text('Custom commands'),
            subtitle: const Text('Prompts saved as Markdown files, run with / in a composer'),
            onTap: () => context.go(Routes.commands),
          ),
          if (Host.isDesktop) ...[
            const AdaptiveSectionHeader('Code'),
            AdaptiveListTile(
              title: const Text('MCP servers'),
              subtitle: Text(_mcpSummary(ref.watch(codeMcpServersProvider))),
              onTap: () => context.go(Routes.mcpServers),
            ),
            AdaptiveListTile(
              title: const Text('Skills'),
              subtitle: const Text('SKILL.md folders the agent loads when a task needs them'),
              onTap: () => context.go(Routes.skills),
            ),
          ],
          const AdaptiveSectionHeader('Account'),
          AdaptiveListTile(
            title: const Text('Plan & usage'),
            subtitle: const Text('Your plan, included usage, wallet and top-ups'),
            onTap: () => context.go(Routes.billing),
          ),
          switch (auth) {
            Bypassed() => const AdaptiveListTile(
              title: Text('Signed out (development mode)'),
              subtitle: Text('Sign-in is skipped while DEV_SKIP_AUTH is on.'),
            ),
            SignedIn() => AdaptiveListTile(
              title: const Text('Signed in'),
              trailing: AdaptiveButton(
                label: 'Sign out',
                emphasis: ButtonEmphasis.destructive,
                onPressed: () async {
                  final ok = await showAdaptiveConfirm(
                    context,
                    title: 'Sign out?',
                    message: 'Chats stay on this device.',
                    confirmLabel: 'Sign out',
                    destructive: true,
                  );
                  if (ok) await ref.read(authProvider.notifier).signOut();
                },
              ),
            ),
            _ => const SizedBox.shrink(),
          },
          if (config.devSkipAuth) ...[
            const AdaptiveSectionHeader('Developer'),
            switch (ref.watch(devUpstreamProvider)) {
              AsyncData(:final value) => AdaptiveListTile(
                title: const Text('Claude models bill to'),
                subtitle: Text(
                  value.hasAnthropicKey
                      ? 'Search and Research always use OpenRouter.'
                      : 'Set ANTHROPIC_API_KEY on the server to use your Anthropic key.',
                ),
                trailing: value.hasAnthropicKey
                    ? picker(value.claude.label, [
                        for (final u in ClaudeUpstream.values) (u.label, u),
                      ], ref.read(devUpstreamProvider.notifier).set)
                    : Text(value.claude.label, style: TextStyle(color: theme.textMuted)),
              ),
              AsyncError() => const AdaptiveListTile(
                title: Text('Claude models bill to'),
                subtitle: Text("Couldn't reach the server's dev settings."),
              ),
              _ => const AdaptiveListTile(title: Text('Claude models bill to')),
            },
          ],
          const AdaptiveSectionHeader('About'),
          AdaptiveListTile(title: const Text('Server'), subtitle: Text(config.apiBaseUrl.toString())),
          const AdaptiveListTile(title: Text('Version'), subtitle: Text('0.1.0')),
        ],
      ),
    );
  }
}

/// "2 on, 1 waiting for approval" for the MCP servers row.
String _mcpSummary(StoredMcpServers stored) {
  final all = [...stored.global, for (final l in stored.projects.values) ...l];
  if (all.isEmpty) return 'Tools for Code sessions: Playwright, draw.io and your own';
  final on = all.where((s) => s.active).length;
  final waiting = all.where((s) => s.enabled && s.needsConsent && s.problem == null).length;
  return '$on on${waiting == 0 ? '' : ', $waiting waiting for approval'}';
}
