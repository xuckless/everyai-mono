// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/widgets.dart';

import '../../../core/preferences.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../live/real_input.dart';

/// Connects [RealInput] to the app: the remembered answer from [prefs], and the one-time dialog shown over
/// [context] (the shell's) the first time an agent needs the real pointer or keyboard.
void connectRealInput(Preferences prefs, BuildContext Function() context) {
  RealInput.allowed ??= switch (prefs[RealInput.prefKey]) {
    '1' => true,
    '0' => false,
    _ => null,
  };
  RealInput.save = (yes) => prefs[RealInput.prefKey] = yes ? '1' : '0';
  RealInput.ask = () {
    final c = context();
    return c.mounted ? showRealInputConsent(c) : Future.value(false);
  };
}

/// Asks once whether agents may use the real pointer and keyboard on app windows. True to allow.
Future<bool> showRealInputConsent(BuildContext context) async {
  final yes = await showKitDialog<bool>(
    context,
    dismissible: false,
    builder: (ctx) {
      final theme = EveryTheme.of(ctx);
      return KitDialog(
        title: 'Let agents use your mouse and keyboard?',
        width: 460,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Some app windows (Tk, games, canvases) can\'t be driven in the background. The agent would bring the '
              'window forward and use your real pointer and keyboard. Avoid using them meanwhile. It never types '
              'into password fields.',
            ),
            const SizedBox(height: 10),
            Text('Change this later in Settings > Code.', style: theme.type.caption.tint(theme.textMuted)),
          ],
        ),
        actions: [
          KitButton(label: "Don't allow", style: KitButtonStyle.ghost, onPressed: () => Navigator.of(ctx).pop(false)),
          KitButton(label: 'Allow', onPressed: () => Navigator.of(ctx).pop(true)),
        ],
      );
    },
  );
  return yes ?? false;
}
