// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/foundation.dart';

/// Where a project's commands, CLIs and git run: this computer, or an
/// environment reached through an exec bridge (a WSL distro, a container, a
/// Linux VM, an SSH remote). The bridges are in `bridges.dart`, discovery in
/// `discovery.dart`, the CLI scan inside one in `environment_scan.dart`.
enum EnvKind {
  host('This computer'),
  wsl('WSL'),
  container('Container'),
  vm('VM'),
  ssh('SSH');

  const EnvKind(this.label);
  final String label;
}

@immutable
abstract class ExecEnv {
  const ExecEnv();

  /// Stable id stored on a project (`CodeProject.environment`): 'host',
  /// `wsl:Ubuntu`, `docker:<context>/<name>`, `devcontainer:<folder>`,
  /// `lima:default`, `orb:<machine>`, `multipass:<name>`, `colima:<profile>`,
  /// `ssh:<alias>`.
  String get id;

  EnvKind get kind;

  /// Plain name for lists: "Ubuntu (WSL)", "dev (Container)".
  String get label;

  bool get isHost => kind == EnvKind.host;

  /// Whether it can take commands now. A stopped distro, VM or container is
  /// listed but never scanned or started by the app.
  bool get running => true;

  /// Something the user should know about it, in plain words ("Your home
  /// folder is read-only inside"), or null.
  String? get note => null;

  /// The host command line that runs [executable] with [args] inside this
  /// environment, in [cwd] (a path inside the environment) with [env] set.
  /// [WrappedCommand.environment] goes to the host process (added to the
  /// login shell's): bridges that can forward variables by name (WSLENV,
  /// `docker exec -e K`) keep the values out of the host's argv that way.
  /// The bridge takes care of [cwd], so for an environment other than the
  /// host the caller passes no host working directory. The host environment
  /// returns everything unchanged.
  WrappedCommand wrap(String executable, List<String> args, {String? cwd, Map<String, String> env = const {}});

  /// A host path as the environment sees it (and [toHostPath] back). Identity
  /// on the host; null when the path isn't reachable from the other side.
  String? toEnvPath(String hostPath);
  String? toHostPath(String envPath);

  /// Whether a program inside can write under [hostPath] (a worktree EveryAI
  /// makes there): it is visible inside and its share isn't read-only.
  bool writableInside(String hostPath) => toEnvPath(hostPath) != null;

  /// How a loopback URL served on the host (the MCP host) is reached from
  /// inside, or null when it can't be. Identity on the host.
  Uri? hostUrl(Uri loopback) => loopback;
}

/// What [ExecEnv.wrap] gives: the host process to start and the variables to
/// add to its environment.
typedef WrappedCommand = ({String executable, List<String> args, Map<String, String> environment});

/// This computer.
final class HostEnv extends ExecEnv {
  const HostEnv();

  static const instance = HostEnv();

  @override
  String get id => 'host';

  @override
  EnvKind get kind => EnvKind.host;

  @override
  String get label => EnvKind.host.label;

  @override
  WrappedCommand wrap(String executable, List<String> args, {String? cwd, Map<String, String> env = const {}}) =>
      (executable: executable, args: args, environment: env);

  @override
  String? toEnvPath(String hostPath) => hostPath;

  @override
  String? toHostPath(String envPath) => envPath;
}
