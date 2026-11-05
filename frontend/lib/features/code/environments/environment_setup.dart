// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'exec_env.dart';

/// Whether "Set up in" an environment can be offered next to a harness that
/// is not installed there. False until the one-step setup (the detect lane's)
/// takes an environment; the UI hides the button meanwhile.
const setupAvailable = false;

/// Installs [driverId]'s CLI inside [env] and signs it in.
///
/// TODO(e3): call the detect lane's one-step setup with [env] at integration,
/// then set [setupAvailable]. Nothing calls this while it is false.
Future<void> openSetupIn(ExecEnv env, String driverId) =>
    throw UnimplementedError('The one-step setup does not take an environment yet.');
