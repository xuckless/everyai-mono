// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/motion/motion.dart';
import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/every_icons.dart';
import '../../code_providers.dart' show codeSessionsProvider;
import '../../live/agent_logins.dart';

/// "Let the agent sign in with github?": the session's agent waits to fill a saved login while the user wants to be
/// asked first (Settings > Code > Logins). Above the composer and on the Board. Allow lasts for the session (the
/// Preview's key menu and Settings can stop it); Deny tells the agent no. Nothing while no fill waits.
///
/// A fork or workflow agent asks on its own session id; its card shows here too (where the user is), naming it.
///
/// No state of its own: it follows [LoginGate.asks].
class LoginAskCard extends ConsumerWidget {
  const LoginAskCard({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The session's forks and workflow agents, by id, with their titles for the card.
    final children = ref.watch(
      codeSessionsProvider.select(
        (all) => {
          for (final s in all)
            if (s.parentId == sessionId) s.id: s.title,
        },
      ),
    );
    return ValueListenableBuilder<List<LoginAsk>>(
      valueListenable: LoginGate.asks,
      builder: (context, _, _) => _cards(context, LoginGate.asksOf({sessionId, ...children.keys}), children),
    );
  }

  Widget _cards(BuildContext context, List<LoginAsk> mine, Map<String, String> children) {
    if (mine.isEmpty) return const SizedBox.shrink();
    final theme = EveryTheme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final a in mine)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Container(
              key: ValueKey('login-ask.${a.gate.session}.${a.login}'),
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              decoration: BoxDecoration(
                color: theme.accentBg,
                border: Border.all(color: theme.accent.withValues(alpha: 0.6)),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 6,
                runSpacing: 6,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AdaptiveIcon(EveryIcon.key, size: 15, color: theme.accent),
                      const SizedBox(width: 10),
                      // Wraps in a narrow pane rather than running past it.
                      Flexible(
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(text: 'Sign in with ${a.login}?', style: theme.type.callout.semibold),
                              TextSpan(
                                text: switch (children[a.gate.session]) {
                                  null => '  · the agent wants your saved login for ${a.site}',
                                  final fork =>
                                    '  · ${fork.isEmpty ? 'a fork' : '"$fork"'} wants your saved login for ${a.site}',
                                },
                                style: theme.type.caption.tint(theme.textMuted),
                              ),
                            ],
                          ),
                          style: theme.type.callout.tint(theme.text),
                        ),
                      ),
                    ],
                  ),
                  AdaptiveButton(
                    key: ValueKey('login-ask.allow.${a.gate.session}.${a.login}'),
                    label: 'Allow',
                    onPressed: () => a.gate.answer(a.login, allow: true),
                  ),
                  AdaptiveButton(
                    key: ValueKey('login-ask.deny.${a.gate.session}.${a.login}'),
                    label: 'Deny',
                    emphasis: ButtonEmphasis.secondary,
                    onPressed: () => a.gate.answer(a.login, allow: false),
                  ),
                ],
              ),
            ).settle(),
          ),
      ],
    );
  }
}
