// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:io' show Platform;

/// Whether the agent may use the real pointer and keyboard on desktop windows (it moves the user's cursor, brings
/// the window to the front and types into it) when accessibility can't do a job. Asked once, in a dialog the app
/// shows ([ask]), and remembered ([save]); Settings > Code changes it.
abstract final class RealInput {
  /// Preferences key: '1' allowed, '0' refused, absent not asked yet.
  static const prefKey = 'code.desktop.real_input';

  /// The remembered answer (null: not asked yet).
  static bool? allowed = switch (Platform.environment['EVERYAI_REAL_INPUT']) {
    '1' => true,
    '0' => false,
    _ => null,
  };

  /// The app's one-time dialog: true to allow. Unset (tests, dev rigs) means no.
  static Future<bool> Function()? ask;

  /// Keeps the answer (the app writes it to its preferences).
  static void Function(bool allowed)? save;

  static Future<bool>? _asking;

  /// Whether real input may be used now, asking the user the first time.
  static Future<bool> ensure() async {
    if (allowed case final a?) return a;
    final dialog = ask;
    if (dialog == null) return false;
    return _asking ??= () async {
      try {
        final yes = await dialog();
        set(yes);
        return yes;
      } finally {
        _asking = null;
      }
    }();
  }

  /// Sets the answer and keeps it.
  static void set(bool yes) {
    allowed = yes;
    save?.call(yes);
  }

  /// What an action says when it needed real input and the user said no.
  static const refused =
      'The user turned off real pointer and keyboard input for desktop windows (Settings > Code), so only '
      'accessibility actions work here';
}
