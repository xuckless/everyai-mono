// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../driver.dart';
import '../driver_process.dart' show notBuiltProblem;

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
/// is installed) merely makes a missing CLI offerable. A check that failed
/// (`problem` on a status that is not installed) is never offered on a guess.
/// A CLI that is there but cannot lead (another program of the same name, one
/// that will not run, too old) is Set up, to fix or update it, so Ready always
/// means [leadBlocked] has nothing to say about the CLI.
CliState cliStateOf(DriverStatus status, {bool appFound = false}) {
  if (!status.installed) return appFound && status.problem == null ? CliState.setUp : CliState.absent;
  if (status.problem == notBuiltProblem) return CliState.absent;
  if (status.signedIn == false) return CliState.signIn;
  return status.problem == null ? CliState.ready : CliState.setUp;
}
