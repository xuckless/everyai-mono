import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/billing_flag.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/layout.dart';
import '../../auth/auth_providers.dart';
import '../../auth/domain/auth_state.dart';
import '../../auth/email_change.dart';
import '../../auth/profile.dart';
import '../../auth/ui/magic_sign_in.dart';
import '../settings_registry.dart';
import 'account_menu.dart';
import 'settings_modal.dart';

/// Preferences → Account. Signed out: what an account adds, and the magic
/// link. Signed in: who, the sign-in history, a new address, and logging
/// out here or everywhere.
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
                          plan,
                        ].where((s) => s.isNotEmpty).join(' · '),
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
              if (BillingFlag.enabled && auth is SignedIn)
                KitButton(
                  key: const ValueKey('settings.account.plan'),
                  label: 'Manage plan',
                  style: KitButtonStyle.soft,
                  onPressed: () => showSettings(context, section: SettingsSection.billing),
                ),
            ],
          ),
        ),
        ...switch (auth) {
          Restoring() => const <Widget>[],
          SignedOut(:final error) => [
            SettingsAnchor(
              section: SettingsSection.account,
              id: 'sign-in',
              child: AdaptiveListTile(
                title: const Text('No account needed'),
                subtitle: Text(
                  error ??
                      'Chat, Code, your keys and remote control all work without one. Sign in to see your paired '
                          'computers on every device, and for sync later.',
                ),
                trailing: AdaptiveButton(
                  key: const ValueKey('settings.sign-in'),
                  label: 'Sign in',
                  onPressed: () => ref.read(authProvider.notifier).startSignIn(),
                ),
              ),
            ),
          ],
          SigningIn() => [
            SettingsAnchor(
              section: SettingsSection.account,
              id: 'sign-in',
              child: const KitCard(child: MagicSignIn()),
            ),
          ],
          SignedIn() || SigningOut() => [
            const _EmailRow(),
            const _History(),
            SettingsAnchor(
              section: SettingsSection.account,
              id: 'sign-out',
              child: AdaptiveListTile(
                title: const Text('Log out of this device'),
                subtitle: const Text('Chats and remote pairings stay on this device.'),
                trailing: AdaptiveButton(
                  key: const ValueKey('settings.sign-out'),
                  label: 'Log out',
                  emphasis: ButtonEmphasis.destructive,
                  onPressed: auth is SigningOut ? null : () => confirmSignOut(context, ref),
                ),
              ),
            ),
            AdaptiveListTile(
              title: const Text('Log out everywhere'),
              subtitle: const Text('Every device signed in to this account signs out, this one too.'),
              trailing: AdaptiveButton(
                key: const ValueKey('settings.sign-out-all'),
                label: 'Log out all',
                emphasis: ButtonEmphasis.destructive,
                onPressed: auth is SigningOut ? null : () => _confirmEverywhere(context, ref),
              ),
            ),
          ],
        },
      ],
    );
  }

  static Future<void> _confirmEverywhere(BuildContext context, WidgetRef ref) async {
    final ok = await showAdaptiveConfirm(
      context,
      title: 'Log out everywhere?',
      message: 'Every device signed in to this account has to sign in again. Chats and pairings stay.',
      confirmLabel: 'Log out all',
      destructive: true,
    );
    if (ok) await ref.read(authProvider.notifier).signOutEverywhere();
  }
}

/// The account's address, and moving it to another one by magic link.
class _EmailRow extends ConsumerStatefulWidget {
  const _EmailRow();

  @override
  ConsumerState<_EmailRow> createState() => _EmailRowState();
}

class _EmailRowState extends ConsumerState<_EmailRow> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _ask() async {
    final email = await showAdaptivePrompt(
      context,
      title: 'New email address',
      confirmLabel: 'Send link',
      placeholder: 'you@example.com',
    );
    if (email == null || email.trim().isEmpty) return;
    await ref.read(emailChangeProvider.notifier).send(email);
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final change = ref.watch(emailChangeProvider);
    final email = ref.watch(profileProvider).value?.email ?? '';
    final controller = ref.read(emailChangeProvider.notifier);
    return switch (change) {
      EmailAwaitingLink(email: final to, :final codeError) => AdaptiveListTile(
        title: Text('Check $to'),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(codeError ?? 'Press Sign in in that email, or type its code.'),
            const SizedBox(height: 8),
            SizedBox(
              width: 180,
              child: AdaptiveTextField(
                key: const ValueKey('settings.email.code'),
                controller: _code,
                placeholder: '6-digit code',
                keyboardType: TextInputType.number,
                onChanged: (v) {
                  final digits = v.replaceAll(RegExp(r'\D'), '');
                  if (digits.length == 6) controller.enterCode(digits);
                },
              ),
            ),
          ],
        ),
        trailing: AdaptiveButton(label: 'Cancel', emphasis: ButtonEmphasis.secondary, onPressed: controller.cancel),
      ),
      _ => AdaptiveListTile(
        title: const Text('Email'),
        subtitle: Text(
          [email, if (change case EmailIdle(:final note?)) note].where((s) => s.isNotEmpty).join(' · '),
          style: theme.type.caption.tint(theme.textMuted),
        ),
        trailing: AdaptiveButton(
          key: const ValueKey('settings.email.change'),
          label: change is EmailSending ? 'Sending…' : 'Change',
          emphasis: ButtonEmphasis.secondary,
          onPressed: change is EmailSending ? null : _ask,
        ),
      ),
    };
  }
}

/// The last sign-ins of this account: when, which device, which network.
class _History extends ConsumerWidget {
  const _History();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final rows = ref.watch(signInHistoryProvider).value ?? const [];
    if (rows.isEmpty) return const SizedBox.shrink();
    String when(DateTime t) {
      final l = t.toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
    }

    return KitCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const KitLabel('Recent sign-ins'),
          const SizedBox(height: 6),
          for (final r in rows.take(8))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Expanded(child: Text(r.device, style: theme.type.callout.tint(theme.text))),
                  Text(
                    '${when(r.at)} · ${r.network} · ${r.method == 'code' ? 'code' : 'link'}',
                    style: theme.type.caption.mono.tint(theme.textMuted),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
