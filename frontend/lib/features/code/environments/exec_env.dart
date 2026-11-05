// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/foundation.dart';

/// Where a project's commands, CLIs and git run: this computer, or an
/// environment reached through an exec bridge (a WSL distro, a container, a
/// Linux VM, an SSH remote). Seam for the multi-harness "Next 1–3" batch: the
/// environments lane fills in discovery and the bridges; the rest of the app
/// codes against this interface.
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
  /// `wsl:Ubuntu`, `docker:<name>`, `lima:default`, `ssh:<alias>`, ...
  String get id;

  EnvKind get kind;

  /// Plain name for lists: "Ubuntu (WSL)", "dev (Container)".
  String get label;

  bool get isHost => kind == EnvKind.host;

  /// The host command line that runs [executable] with [args] inside this
  /// environment, in [cwd] (a path inside the environment) with [env] set.
  /// The host environment returns them unchanged.
  ({String executable, List<String> args}) wrap(
    String executable,
    List<String> args, {
    String? cwd,
    Map<String, String> env = const {},
  });

  /// A host path as the environment sees it (and [toHostPath] back). Identity
  /// on the host; null when the path isn't reachable from the other side.
  String? toEnvPath(String hostPath);
  String? toHostPath(String envPath);

  /// How a loopback URL served on the host (the MCP host) is reached from
  /// inside. Identity on the host.
  Uri hostUrl(Uri loopback) => loopback;
}

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
  ({String executable, List<String> args}) wrap(
    String executable,
    List<String> args, {
    String? cwd,
    Map<String, String> env = const {},
  }) => (executable: executable, args: args);

  @override
  String? toEnvPath(String hostPath) => hostPath;

  @override
  String? toHostPath(String envPath) => envPath;
}
