import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/motion/motion.dart';
import '../../../core/platform/platform_kind.dart';
import '../../../core/providers.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/layout.dart';
import '../../../core/ui/every_icons.dart';
import '../../agents/ui/agents_settings_screen.dart';
import '../../auth/auth_providers.dart';
import '../../auth/domain/auth_state.dart';
import '../../auth/profile.dart';
import '../../billing/ui/billing_screen.dart';
import '../../code/automations/ui/scheduled_tasks_body.dart';
import '../../code/code_settings_providers.dart' show SettingsScope;
import '../../code/ui/code_settings_section.dart';
import '../../code/ui/mcp_settings_screen.dart';
import '../../memory/ui/memory_screen.dart';
import '../../models/models_providers.dart';
import '../../models/ui/model_avatar.dart';
import '../../remote/ui/remote_settings_screen.dart';
import '../../skills/ui/skills_settings_screen.dart';
import '../../slash/custom/custom_commands_screen.dart';
import '../../usage/ui/usage_screen.dart';
import '../appearance.dart';
import '../dev_upstream.dart';
import '../reply_language.dart';
import '../settings_registry.dart';
import '../../updates/ui/update_banner.dart';
import '../../../core/config/version.dart';
import 'account_menu.dart';
import 'api_keys_section.dart';
import 'notices_screen.dart';
import 'settings_modal.dart';

/// The body of [section] in the Settings modal; [args] as `showSettings` got them.
Widget settingsSectionBody(SettingsSection section, Map<String, String> args) => switch (section) {
  SettingsSection.general => const GeneralSection(),
  SettingsSection.account => const AccountSection(),
  SettingsSection.apiKeys => const ApiKeysSection(),
  SettingsSection.billing => const BillingBody(),
  SettingsSection.usage => const UsageBody(),
  SettingsSection.models => const ModelsSection(),
  SettingsSection.memory => const MemoryBody(),
  SettingsSection.code => CodeSettingsSection(
    projectId: args['project'],
    sessionId: args['session'],
    scope: args['scope'] == null ? null : SettingsScope.parse(args['scope']),
  ),
  SettingsSection.permissions => const PermissionsSection(),
  SettingsSection.schedules => const ScheduledTasksBody(),
  SettingsSection.mcp => McpSettingsBody(projectId: args['project']),
  SettingsSection.skills => SkillsSettingsBody(projectId: args['project']),
  SettingsSection.agents => const AgentsSettingsBody(),
  SettingsSection.commands => const CustomCommandsBody(),
  SettingsSection.remote => const RemoteSettingsBody(),
  SettingsSection.developer => const DeveloperSection(),
  SettingsSection.about => const AboutSection(),
};

/// A value picker: the current value, a menu of the options.
Widget settingsPicker<T>(String current, List<(String, T)> options, ValueChanged<T> onPick, {Key? key}) =>
    AdaptiveMenuButton(
      key: key,
      actions: [
        for (final (label, value) in options)
          MenuAction(label: label, checked: label == current, onSelected: () => onPick(value)),
      ],
      child: MenuTrigger(current),
    );

/// Preferences → General: appearance, the default chat model and the reply language.
class GeneralSection extends ConsumerWidget {
  const GeneralSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(appearanceProvider);
    final appearanceCtl = ref.read(appearanceProvider.notifier);
    final defaultModel = ref.watch(defaultModelProvider);
    final library = ref.watch(libraryProvider).value ?? const [];
    final language = ref.watch(replyLanguageProvider);
    const s = SettingsSection.general;
    return KitGroupedList(
      children: [
        const AdaptiveSectionHeader('Appearance'),
        SettingsAnchor(
          section: s,
          id: 'theme',
          child: ThemeCards(selected: appearance.theme, onSelected: appearanceCtl.setTheme),
        ),
        if (appearance.theme != ThemePreference.light)
          SettingsAnchor(
            section: s,
            id: 'pure-black',
            child: AdaptiveListTile(
              title: const Text('Pure black'),
              trailing: AdaptiveSwitch(
                key: const ValueKey('settings.pure-black'),
                value: appearance.pureBlack,
                onChanged: appearanceCtl.setPureBlack,
              ),
            ),
          ),
        SettingsAnchor(
          section: s,
          id: 'reduce-motion',
          child: AdaptiveListTile(
            title: const Text('Reduce motion'),
            trailing: AdaptiveSwitch(
              key: const ValueKey('settings.reduce-motion'),
              value: appearance.reduceMotion,
              onChanged: appearanceCtl.setReduceMotion,
            ),
          ),
        ),
        const AdaptiveSectionHeader('Chat'),
        SettingsAnchor(
          section: s,
          id: 'default-model',
          child: AdaptiveListTile(
            title: const Text('Default model'),
            trailing: settingsPicker(defaultModel.name, [
              for (final m in {...library, defaultModel}) (m.name, m),
            ], ref.read(defaultModelProvider.notifier).set),
          ),
        ),
        SettingsAnchor(
          section: s,
          id: 'language',
          child: AdaptiveListTile(
            title: const Text('Reply language'),
            subtitle: const Text('Chat answers and suggested follow-ups. The app itself stays in English.'),
            trailing: settingsPicker(
              key: const ValueKey('settings.language'),
              language == ReplyLanguage.auto ? 'Same as my message' : language,
              [('Same as my message', ReplyLanguage.auto), for (final l in replyLanguages) (l, l)],
              ref.read(replyLanguageProvider.notifier).set,
            ),
          ),
        ),
      ],
    );
  }
}

/// Preferences → Account: who is signed in, and signing out.
class AccountSection extends ConsumerWidget {
  const AccountSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final auth = ref.watch(authProvider);
    final profile = ref.watch(profileProvider).value;
    final (name, plan) = accountSummary(auth, profile);
    return KitGroupedList(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 18),
          child: WrapRow(
            lead: Row(
              children: [
                AccountAvatar(name: name, size: 44),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, style: theme.type.headline.tint(theme.text)),
                      Text(
                        [
                          if (profile != null && profile.email.isNotEmpty) profile.email,
                          plan.isEmpty ? 'Not signed in' : plan,
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.type.caption.tint(theme.textSubtle),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              KitButton(
                key: const ValueKey('settings.account.plan'),
                label: 'Manage plan',
                style: KitButtonStyle.soft,
                onPressed: () => showSettings(context, section: SettingsSection.billing),
              ),
            ],
          ),
        ),
        SettingsAnchor(
          section: SettingsSection.account,
          id: 'sign-out',
          child: switch (auth) {
            Bypassed() => const AdaptiveListTile(
              title: Text('Signed out (development mode)'),
              subtitle: Text('Sign-in is skipped while DEV_SKIP_AUTH is on.'),
            ),
            SignedIn() => AdaptiveListTile(
              title: const Text('Log out of this device'),
              subtitle: const Text('Chats stay on this device.'),
              trailing: AdaptiveButton(
                key: const ValueKey('settings.sign-out'),
                label: 'Log out',
                emphasis: ButtonEmphasis.destructive,
                onPressed: () => confirmSignOut(context, ref),
              ),
            ),
            _ => const SizedBox.shrink(),
          },
        ),
      ],
    );
  }
}

/// Preferences → Models: My models, and a way to the shop.
class ModelsSection extends ConsumerWidget {
  const ModelsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final library = ref.watch(libraryProvider).value ?? const [];
    return KitGroupedList(
      children: [
        WrapRow(
          lead: Text(
            'The models in your pickers. Add more from the shop.',
            style: theme.type.callout.tint(theme.textMuted),
          ),
          actions: [
            AdaptiveButton(
              key: const ValueKey('settings.models.shop'),
              label: 'Open model shop',
              emphasis: ButtonEmphasis.secondary,
              onPressed: () {
                final router = GoRouter.of(context);
                closeSettings(context);
                router.go(Routes.models);
              },
            ),
          ],
        ),
        const AdaptiveSectionHeader('My models'),
        for (final m in library)
          AdaptiveListTile(
            leading: ModelAvatar(m.provider, size: 26),
            title: Text(m.name),
            subtitle: Text(m.id.value),
            trailing: AdaptiveIconButton(
              icon: EveryIcon.close,
              tooltip: 'Remove from My models',
              size: 14,
              onPressed: () => ref.read(libraryProvider.notifier).toggle(m),
            ),
          ),
        if (library.isEmpty)
          AdaptiveListTile(title: Text('No models yet', style: theme.type.body.tint(theme.textMuted))),
      ],
    );
  }
}

/// This computer → Developer: switches for development builds.
class DeveloperSection extends ConsumerWidget {
  const DeveloperSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final config = ref.watch(appConfigProvider);
    return KitGroupedList(
      children: [
        if (!config.devSkipAuth)
          AdaptiveListTile(
            title: const Text('Nothing to set here'),
            subtitle: Text(
              'Developer switches show in development builds (DEV_SKIP_AUTH).',
              style: theme.type.body.tint(theme.textMuted),
            ),
          )
        else
          switch (ref.watch(devUpstreamProvider)) {
            AsyncData(:final value) => AdaptiveListTile(
              title: const Text('Claude models bill to'),
              subtitle: Text(
                value.hasAnthropicKey
                    ? 'Search and Research always use OpenRouter.'
                    : 'Set ANTHROPIC_API_KEY on the server to use your Anthropic key.',
              ),
              trailing: value.hasAnthropicKey
                  ? settingsPicker(value.claude.label, [
                      for (final u in ClaudeUpstream.values) (u.label, u),
                    ], ref.read(devUpstreamProvider.notifier).set)
                  : Text(value.claude.label, style: theme.type.body.tint(theme.textMuted)),
            ),
            AsyncError() => const AdaptiveListTile(
              title: Text('Claude models bill to'),
              subtitle: Text("Couldn't reach the server's dev settings."),
            ),
            _ => const AdaptiveListTile(title: Text('Claude models bill to')),
          },
      ],
    );
  }
}

/// About: version, server, and the third-party notices (a page of their own).
class AboutSection extends ConsumerStatefulWidget {
  const AboutSection({super.key});

  @override
  ConsumerState<AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends ConsumerState<AboutSection> {
  bool _notices = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final config = ref.watch(appConfigProvider);
    if (_notices) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: AdaptiveButton(
              label: 'About',
              emphasis: ButtonEmphasis.plain,
              icon: const AdaptiveIcon(EveryIcon.chevronLeft, size: 13),
              onPressed: () => setState(() => _notices = false),
            ),
          ),
          const Expanded(child: NoticesBody()),
        ],
      );
    }
    return KitGroupedList(
      children: [
        AdaptiveListTile(title: const Text('Version'), subtitle: const Text(appVersion)),
        const UpdateSettingsTiles(),
        AdaptiveListTile(title: const Text('Server'), subtitle: Text(config.apiBaseUrl.toString())),
        AdaptiveListTile(
          title: const Text('Platform'),
          subtitle: Text('${Host.isDesktop ? 'Desktop' : 'Mobile or web'} · Geist'),
        ),
        SettingsAnchor(
          section: SettingsSection.about,
          id: 'notices',
          child: AdaptiveListTile(
            key: const ValueKey('settings.notices'),
            title: const Text('Third-party notices'),
            subtitle: const Text('Open-source software EveryAI includes, and its licenses'),
            trailing: AdaptiveIcon(EveryIcon.chevronRight, size: 13, color: theme.textMuted),
            onTap: () => setState(() => _notices = true),
          ),
        ),
      ],
    );
  }
}

/// The theme as three small pictures of the app (System is split light/dark); the picked one has an accent ring
/// that eases between cards.
class ThemeCards extends StatelessWidget {
  const ThemeCards({super.key, required this.selected, required this.onSelected});

  final ThemePreference selected;
  final ValueChanged<ThemePreference> onSelected;

  static const _order = [ThemePreference.system, ThemePreference.dark, ThemePreference.light];

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    Widget picture(ThemePreference t) {
      const dark = (Color(0xFF07070A), Color(0xFF16161A), Color(0xFF0E0E12));
      const light = (Color(0xFFFAFAFE), Color(0xFFECEBF2), Color(0xFFFFFFFF));
      Widget half((Color, Color, Color) c) => ColoredBox(
        color: c.$1,
        child: Padding(
          padding: const EdgeInsets.all(7),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 3,
                child: DecoratedBox(
                  decoration: BoxDecoration(color: c.$2, borderRadius: BorderRadius.circular(4)),
                ),
              ),
              const SizedBox(width: 5),
              Expanded(
                flex: 8,
                child: DecoratedBox(
                  decoration: BoxDecoration(color: c.$3, borderRadius: BorderRadius.circular(4)),
                ),
              ),
            ],
          ),
        ),
      );
      return switch (t) {
        ThemePreference.dark => half(dark),
        ThemePreference.light => half(light),
        ThemePreference.system => Stack(
          fit: StackFit.expand,
          children: [
            half(dark),
            ClipRect(clipper: const _RightHalf(), child: half(light)),
          ],
        ),
      };
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Semantics(
        container: true,
        label: 'Theme',
        child: Row(
          key: const ValueKey('settings.theme'),
          children: [
            for (final (i, t) in _order.indexed) ...[
              if (i > 0) const SizedBox(width: 10),
              Expanded(
                child: Pressable(
                  key: ValueKey('settings.theme.${t.name}'),
                  onTap: () => onSelected(t),
                  selected: t == selected,
                  semanticLabel: t.label,
                  child: AnimatedContainer(
                    duration: Motion.reduced(context) ? Duration.zero : Motion.swap,
                    curve: Motion.easeInOut,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: t == selected ? theme.accent : theme.border,
                        width: t == selected ? 1.5 : 1,
                      ),
                    ),
                    child: Column(
                      children: [
                        SizedBox(
                          height: 70,
                          child: DecoratedBox(
                            position: DecorationPosition.foreground,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(9),
                              border: Border.all(color: theme.border),
                            ),
                            child: ClipRRect(borderRadius: BorderRadius.circular(9), child: picture(t)),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(t.label, style: theme.type.callout.medium.tint(theme.text)),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RightHalf extends CustomClipper<Rect> {
  const _RightHalf();

  @override
  Rect getClip(Size size) => Rect.fromLTWH(size.width / 2, 0, size.width / 2, size.height);

  @override
  bool shouldReclip(_RightHalf old) => false;
}
