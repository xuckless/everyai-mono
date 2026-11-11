// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/preferences.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../domain/agent_mode.dart';

/// Whether the user agreed that an outside lead may run in its own skip-permissions mode (Claude Code's Bypass
/// permissions, Codex's Full Access, Gemini's YOLO, any mode EveryAI names Full auto or Bypass), per harness:
///
/// unasked → asking → allowed (kept) | refusedThisTime (asked again next pick); allowed → unasked from Settings.
enum SkipPermissionsConsent { unasked, asking, allowed, refusedThisTime }

/// Whether [mode] is the lead's own skip-permissions mode (everything runs, nothing asks).
bool skipsPermissions(AgentMode mode) => mode == AgentMode.fullAuto || mode == AgentMode.bypass;

/// What the dialog says about [lead] in that mode.
String skipPermissionsText(String lead) =>
    "$lead will run everything without asking. EveryAI's never-run rules don't apply to it.";

/// The consent per harness id; the allowed ones are kept in preferences ([key], a list of ids).
final skipPermissionsProvider = NotifierProvider<SkipPermissions, Map<String, SkipPermissionsConsent>>(
  SkipPermissions.new,
);

final class SkipPermissions extends Notifier<Map<String, SkipPermissionsConsent>> {
  static const key = 'code.skip_permissions';

  Preferences get _prefs => ref.read(preferencesProvider);

  @override
  Map<String, SkipPermissionsConsent> build() {
    final raw = _prefs[key];
    final saved = raw == null ? null : jsonDecode(raw);
    return {
      if (saved is List<Object?>)
        for (final h in saved.whereType<String>()) h: SkipPermissionsConsent.allowed,
    };
  }

  SkipPermissionsConsent of(String harness) => state[harness] ?? SkipPermissionsConsent.unasked;

  /// unasked | refusedThisTime → asking; false when it is already asking or allowed.
  bool startAsking(String harness) {
    if (of(harness) case SkipPermissionsConsent.asking || SkipPermissionsConsent.allowed) return false;
    _set(harness, SkipPermissionsConsent.asking);
    return true;
  }

  /// asking → allowed | refusedThisTime.
  void answer(String harness, {required bool allowed}) {
    if (of(harness) != SkipPermissionsConsent.asking) return;
    _set(harness, allowed ? SkipPermissionsConsent.allowed : SkipPermissionsConsent.refusedThisTime);
  }

  /// allowed → unasked (Settings → Code → Harnesses, "Ask again").
  void reset(String harness) {
    if (of(harness) == SkipPermissionsConsent.allowed) _set(harness, SkipPermissionsConsent.unasked);
  }

  void _set(String harness, SkipPermissionsConsent c) {
    state = {...state, harness: c};
    _prefs[key] = jsonEncode([
      for (final MapEntry(:key, :value) in state.entries)
        if (value == SkipPermissionsConsent.allowed) key,
    ]);
  }
}

/// Before an outside lead ([harness], shown as [lead]) is put in [mode]: when that is its skip-permissions mode and
/// the user hasn't agreed for this harness, asks once. True to apply the mode; false leaves it as it was. A mode
/// restored from a saved session or a reopen doesn't come through here.
Future<bool> confirmSkipPermissions(
  BuildContext context,
  WidgetRef ref, {
  required String harness,
  required String lead,
  required AgentMode mode,
}) async {
  if (!skipsPermissions(mode)) return true;
  final consent = ref.read(skipPermissionsProvider.notifier);
  if (consent.of(harness) == SkipPermissionsConsent.allowed) return true;
  if (!consent.startAsking(harness)) return false;
  final yes = context.mounted
      ? await showKitDialog<bool>(
          context,
          builder: (ctx) {
            final theme = EveryTheme.of(ctx);
            return KitDialog(
              title: 'Run $lead without asking?',
              width: 460,
              body: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(skipPermissionsText(lead)),
                  const SizedBox(height: 10),
                  Text(
                    'Asked once for $lead. Change it in Settings > Code > Harnesses.',
                    style: theme.type.caption.tint(theme.textMuted),
                  ),
                ],
              ),
              actions: [
                KitButton(
                  label: 'Cancel',
                  style: KitButtonStyle.ghost,
                  shortcut: 'esc',
                  onPressed: () => Navigator.of(ctx).pop(false),
                ),
                KitButton(label: 'Continue', onPressed: () => Navigator.of(ctx).pop(true)),
              ],
            );
          },
        )
      : false;
  consent.answer(harness, allowed: yes ?? false);
  return yes ?? false;
}
