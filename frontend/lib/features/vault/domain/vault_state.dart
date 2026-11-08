import 'package:flutter/foundation.dart';
import 'package:sodium/sodium_sumo.dart';

import 'vault_format.dart';

/// The local vault's lock state. Every change goes through [VaultController]:
///
/// ```text
///   absent ──create──► unlocked
///   locked ──unlock──► unlocking ──key opens──► unlocked ──lock──► locking ──► locked
///                          └──wrong key / bad file──► failed(reason) ──unlock again──► unlocking
///   failed (no header readable) ──create──► unlocked
/// ```
///
/// Only [VaultUnlocked] holds the vault key; locking disposes it (zeroed).
@immutable
sealed class VaultState {
  const VaultState();
}

final class VaultAbsent extends VaultState {
  const VaultAbsent();
}

final class VaultLocked extends VaultState {
  const VaultLocked(this.header);
  final VaultHeader header;
}

final class VaultUnlocking extends VaultState {
  const VaultUnlocking(this.header);
  final VaultHeader header;
}

final class VaultUnlocked extends VaultState {
  const VaultUnlocked(this.header, this.key, this.manifest);
  final VaultHeader header;
  final SecureKey key;
  final Manifest manifest;
}

final class VaultLocking extends VaultState {
  const VaultLocking(this.header);
  final VaultHeader header;
}

/// Unlocking failed ([header] set: try again) or the files can't be read (null).
final class VaultFailed extends VaultState {
  const VaultFailed(this.reason, {this.header});
  final String reason;
  final VaultHeader? header;
}
