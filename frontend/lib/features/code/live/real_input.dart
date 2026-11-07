// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:io' show Platform;

/// Whether the agent may use the real pointer and keyboard on desktop windows (it moves the user's cursor, brings
/// the window to the front and types into it) when accessibility can't do a job. Asked once, in a dialog the app
/// shows ([ask]), and remembered ([save]); Settings > Code changes it.
abstract final class RealInput {
  /// Preferences key: '1' allowed, '0' refused, absent not asked yet.
  static const prefKey = 'code.desktop.real_input';

  /// Where the user's answer is: unasked → (an action needs it) asking → allowed | refused; Settings sets
  /// allowed or refused at any time. `EVERYAI_REAL_INPUT=1|0` starts it answered.
  static RealInputConsent consent = switch (Platform.environment['EVERYAI_REAL_INPUT']) {
    '1' => RealInputConsent.allowed,
    '0' => RealInputConsent.refused,
    _ => RealInputConsent.unasked,
  };

  /// The app's one-time dialog: true to allow. Unset (tests, dev rigs) means no.
  static Future<bool> Function()? ask;

  /// Keeps the answer (the app writes it to its preferences).
  static void Function(bool allowed)? save;

  /// The open dialog's answer while [consent] is asking (every action that needs it waits on the same one).
  static Future<bool>? _dialog;

  /// Whether real input may be used now, asking the user the first time.
  static Future<bool> ensure() async {
    switch (consent) {
      case RealInputConsent.allowed:
        return true;
      case RealInputConsent.refused:
        return false;
      case RealInputConsent.asking:
        return _dialog ?? Future.value(false);
      case RealInputConsent.unasked:
        final dialog = ask;
        if (dialog == null) return false;
        consent = RealInputConsent.asking;
        final answer = _dialog = () async {
          try {
            final yes = await dialog();
            set(yes);
            return yes;
          } on Object {
            // No answer: ask again next time.
            consent = RealInputConsent.unasked;
            rethrow;
          } finally {
            _dialog = null;
          }
        }();
        return answer;
    }
  }

  /// Sets the answer and keeps it (the dialog, or Settings).
  static void set(bool yes) {
    consent = yes ? RealInputConsent.allowed : RealInputConsent.refused;
    save?.call(yes);
  }

  /// What an action says when it needed real input and the user said no.
  static const refused =
      'The user turned off real pointer and keyboard input for desktop windows (Settings > Code), so only '
      'accessibility actions work here';
}

/// The user's answer about real pointer and keyboard input (see [RealInput.consent]).
enum RealInputConsent { unasked, asking, allowed, refused }
