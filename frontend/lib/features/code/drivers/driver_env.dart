// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../environments/exec_env.dart';
import 'driver.dart';

/// What an environment's scan found for a CLI (`environmentScanProvider`):
/// installed, its path inside, its version.
typedef EnvFind = Future<DriverStatus> Function(String command);

/// A driver whose CLI can also run inside an environment (WSL, a container,
/// a VM, an ssh remote): [inEnv] is a copy of it bound to that environment,
/// with its own CLI path, models and live sessions. Its sessions get
/// environment paths in their spec (the controller translates), and its
/// processes start through the environment's bridge.
abstract interface class RunsInEnvironments {
  /// Where this instance runs its CLI; the host for the registry's own.
  ExecEnv get execEnv;

  /// This driver in [env], its CLI looked up with [find] (no host PATH).
  HarnessDriver inEnv(ExecEnv env, EnvFind find);
}

/// [hostDir] as a working directory inside [env] (a probe's app-data folder):
/// the root when the environment can't see it.
String envCwd(ExecEnv env, String hostDir) => env.isHost ? hostDir : env.toEnvPath(hostDir) ?? '/';

/// [envPath] (a briefing folder handed over as the environment sees it) as
/// the host reads it; unchanged when it has no host side.
String hostSide(ExecEnv env, String envPath) => env.isHost ? envPath : env.toHostPath(envPath) ?? envPath;

/// What a driver bound to [env] says when its CLI isn't found inside.
String notInstalledIn(String label, ExecEnv env) => "$label isn't installed in ${env.label}.";
