import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../byok_keys.dart';
import '../domain/byok_providers.dart';
import '../settings_registry.dart';
import 'settings_modal.dart';

/// Preferences → Add API keys: one card per provider. Keys are saved in the
/// system keychain but not used yet (bring-your-own-key isn't wired to the
/// backend), which the banner says.
class ApiKeysSection extends ConsumerWidget {
  const ApiKeysSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final keys = ref.watch(byokKeysProvider).value ?? const <String, String>{};
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Container(
          key: const ValueKey('byok.banner'),
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: theme.accent.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(theme.radius),
            border: Border.all(color: theme.accent.withValues(alpha: 0.35)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AdaptiveIcon(EveryIcon.key, size: 18, color: theme.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Bring your own key — coming soon', style: theme.type.body.semibold.tint(theme.text)),
                    const SizedBox(height: 2),
                    Text(
                      'Keys you add are kept in this device\'s keychain. EveryAI doesn\'t use them yet; once it does, '
                      'requests to that provider will bill to your key.',
                      style: theme.type.caption.tint(theme.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        for (final p in byokProviders)
          SettingsAnchor(
            section: SettingsSection.apiKeys,
            id: p.id,
            child: _ProviderCard(provider: p, last4: keys[p.id]),
          ),
      ],
    );
  }
}

class _ProviderCard extends ConsumerWidget {
  const _ProviderCard({required this.provider, required this.last4});

  final ByokProvider provider;

  /// The saved key's end, or null when there is none.
  final String? last4;

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final key = await showAdaptivePrompt(
      context,
      title: '${provider.name} API key',
      confirmLabel: 'Save',
      obscureText: true,
      placeholder: provider.keyHint.isEmpty ? 'Paste the key' : provider.keyHint,
    );
    if (key == null || key.trim().isEmpty) return;
    try {
      await ref.read(byokKeysProvider.notifier).save(provider.id, key);
      if (context.mounted) showAdaptiveToast(context, '${provider.name} key saved');
    } on Object catch (e) {
      if (context.mounted) showAdaptiveToast(context, "Couldn't save the key: $e");
    }
  }

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final ok = await showAdaptiveConfirm(
      context,
      title: 'Remove the ${provider.name} key?',
      message: 'It is deleted from this device\'s keychain.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (ok) await ref.read(byokKeysProvider.notifier).remove(provider.id);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final connected = last4 != null;
    return Container(
      key: ValueKey('byok.${provider.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.surfaceRaised,
        borderRadius: BorderRadius.circular(theme.radius),
        border: Border.all(color: theme.border),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(color: provider.color, borderRadius: BorderRadius.circular(9)),
            child: Center(
              child: Text(provider.monogram, style: theme.type.callout.semibold.tint(const Color(0xFFFFFFFF))),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(provider.name, style: theme.type.body.medium.tint(theme.text)),
                Text(
                  connected ? '•••• $last4' : 'Not connected',
                  key: ValueKey('byok.${provider.id}.status'),
                  style: (connected ? theme.type.caption.mono : theme.type.caption).tint(
                    connected ? theme.success : theme.textMuted,
                  ),
                ),
              ],
            ),
          ),
          const AdaptiveButton(label: 'Test', emphasis: ButtonEmphasis.plain, onPressed: null),
          const SizedBox(width: 6),
          if (!connected)
            AdaptiveButton(
              key: ValueKey('byok.${provider.id}.add'),
              label: 'Add key',
              emphasis: ButtonEmphasis.secondary,
              onPressed: () => _add(context, ref),
            )
          else
            AdaptiveMenuButton(
              key: ValueKey('byok.${provider.id}.more'),
              actions: [
                MenuAction(label: 'Replace key', icon: EveryIcon.edit, onSelected: () => _add(context, ref)),
                MenuAction(
                  label: 'Remove key',
                  icon: EveryIcon.delete,
                  destructive: true,
                  onSelected: () => _remove(context, ref),
                ),
              ],
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: AdaptiveIcon(EveryIcon.more, size: 15, color: theme.textMuted),
              ),
            ),
        ],
      ),
    );
  }
}
