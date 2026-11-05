// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../driver.dart';

/// What to offer for one harness, decided by its CLI alone.
enum CliState {
  /// The CLI is there and not known to be signed out.
  ready('Ready'),

  /// The CLI is there and says it is signed out.
  signIn('Sign in'),

  /// No CLI, but the vendor's desktop app is installed (see `appFound`), so
  /// setting the CLI up is on offer.
  setUp('Set up'),

  /// No CLI and nothing to set up from.
  absent('Not installed');

  const CliState(this.label);
  final String label;
}

/// The state of [status]. Only the CLI decides: [appFound] (the desktop app
/// is installed) merely makes a missing CLI offerable. A sign-in nobody
/// could check is not a prompt, and a `problem` (too old, a foreign
/// install) stays text beside the state.
CliState cliStateOf(DriverStatus status, {bool appFound = false}) {
  if (!status.installed) return appFound ? CliState.setUp : CliState.absent;
  return status.signedIn == false ? CliState.signIn : CliState.ready;
}
