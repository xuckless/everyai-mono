import 'package:flutter/foundation.dart';

import 'byok_providers.dart';

/// Where one provider's key stands, from the key itself, the last check
/// (persisted per provider) and whether a check runs now:
///
/// ```text
///   unset ──save──► saved ──check──► checking ──200──► connected            (status: connected)
///                     ▲                 │       └─200──► savedNotConnected  (status: saved: never offered)
///                     │                 └──401/403──► rejected
///                     └── replace the key (any state) ──┘          remove (any) ──► unset
///   a check that can't tell (offline, provider down) ──► saved
/// ```
@immutable
sealed class ProviderKeyState {
  const ProviderKeyState();

  /// What the provider's card says.
  String label(String lastFour);

  /// Calls may run on this key.
  bool get usable => false;
}

final class KeyUnset extends ProviderKeyState {
  const KeyUnset();
  @override
  String label(String _) => 'Not connected';
}

/// Saved, not checked yet (or the check couldn't tell).
final class KeySaved extends ProviderKeyState {
  const KeySaved();
  @override
  String label(String lastFour) => '•••• $lastFour';
  @override
  bool get usable => true;
}

final class KeyChecking extends ProviderKeyState {
  const KeyChecking();
  @override
  String label(String lastFour) => '•••• $lastFour · checking…';
}

final class KeyConnected extends ProviderKeyState {
  const KeyConnected(this.checkedAt);
  final DateTime checkedAt;
  @override
  String label(String lastFour) => '•••• $lastFour · works';
  @override
  bool get usable => true;
}

final class KeyRejected extends ProviderKeyState {
  const KeyRejected();
  @override
  String label(String lastFour) => '•••• $lastFour · rejected';
}

/// The key works, but EveryAI doesn't run calls on this provider yet.
final class KeySavedNotConnected extends ProviderKeyState {
  const KeySavedNotConnected();
  @override
  String label(String lastFour) => '•••• $lastFour · saved · not connected yet';
}

/// The last check of a key, kept per provider: which key (its last four),
/// what the provider said (null: couldn't tell) and when.
typedef KeyCheckRecord = ({String tail, bool? valid, DateTime at});

/// The state for [provider] given its saved [key], the last [check] and
/// whether one runs now. A check of another key (replaced since) is ignored.
ProviderKeyState providerKeyState(
  ByokProvider provider, {
  required String? key,
  required KeyCheckRecord? check,
  required bool checking,
}) {
  if (key == null) return const KeyUnset();
  if (checking) return const KeyChecking();
  final tail = key.length <= 4 ? key : key.substring(key.length - 4);
  final c = check != null && check.tail == tail ? check : null;
  if (!provider.connected) return c?.valid == false ? const KeyRejected() : const KeySavedNotConnected();
  return switch (c?.valid) {
    true => KeyConnected(c!.at),
    false => const KeyRejected(),
    null => const KeySaved(),
  };
}
