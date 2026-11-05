// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import 'exec_env.dart';
import 'path_maps.dart';
import 'shell_quote.dart';

// One ExecEnv per kind of exec bridge. Each holds the absolute host path of
// its CLI (`cli`, found at discovery over the login shell's PATH) and what
// discovery learnt (mounts, user, context). Names are checked with safeName
// at discovery; variable names with checkEnvNames on wrap. stdin and stdout
// pass through every bridge untouched (no tty), so the drivers' JSON lines
// work the same inside.

/// `cd CWD && exec [env K=V…] exe args…` for a bridge that runs one shell
/// command line (OrbStack, Colima, ssh).
String bridgeScript(String executable, List<String> args, {String? cwd, Map<String, String> env = const {}}) {
  checkEnvNames(env);
  return [
    if (cwd != null) 'cd ${posixQuote(cwd)} &&',
    'exec',
    if (env.isNotEmpty) ...['env', for (final e in env.entries) posixQuote('${e.key}=${e.value}')],
    posixCommand([executable, ...args]),
  ].join(' ');
}

List<String> _envArgs(Map<String, String> env) {
  checkEnvNames(env);
  return env.isEmpty ? const [] : ['env', for (final e in env.entries) '${e.key}=${e.value}'];
}

/// Loopback URLs only: anything else is already reachable as it is.
Uri? _viaHostName(Uri loopback, String? name) {
  if (!const {'127.0.0.1', 'localhost', '::1'}.contains(loopback.host)) return loopback;
  return name == null ? null : loopback.replace(host: name);
}

/// A WSL distro: `wsl.exe -d D --cd CWD --exec exe args`. `--exec` runs
/// without the distro's shell, so argv is kept (`--` would hand the rest to
/// the default shell, which splits and expands it again). Variables travel
/// by name through WSLENV (`K/u`), with the values in wsl.exe's own
/// environment.
final class WslEnv extends ExecEnv {
  const WslEnv({
    required this.cli,
    required this.distro,
    this.running = true,
    this.root = '/mnt/',
    this.inheritedWslEnv = '',
    this.mirrored = false,
  });

  final String cli;
  final String distro;
  @override
  final bool running;

  /// The automount root (`/etc/wsl.conf`), as `wslpath -u 'C:\'` says less
  /// the drive letter.
  final String root;

  /// The user's own WSLENV, kept in front of ours.
  final String inheritedWslEnv;

  /// Mirrored networking: Windows loopback is loopback inside too.
  final bool mirrored;

  @override
  String get id => 'wsl:$distro';

  @override
  EnvKind get kind => EnvKind.wsl;

  @override
  String get label => '$distro (WSL)';

  @override
  WrappedCommand wrap(String executable, List<String> args, {String? cwd, Map<String, String> env = const {}}) {
    checkEnvNames(env);
    final names = [if (inheritedWslEnv.isNotEmpty) inheritedWslEnv, for (final k in env.keys) '$k/u'];
    return (
      executable: cli,
      args: [
        '-d',
        distro,
        if (cwd != null) ...['--cd', cwd],
        '--exec',
        executable,
        ...args,
      ],
      environment: {...env, if (env.isNotEmpty) 'WSLENV': names.join(':')},
    );
  }

  @override
  String? toEnvPath(String hostPath) => wslToEnvPath(hostPath, distro: distro, root: root);

  @override
  String? toHostPath(String envPath) => wslToHostPath(envPath, distro: distro, root: root);

  // NAT networking can't reach Windows loopback without binding elsewhere.
  @override
  Uri? hostUrl(Uri loopback) => mirrored ? loopback : _viaHostName(loopback, null);
}

/// A running container (plain, or a dev container): `docker [--context C]
/// exec -i [-u USER] [-w CWD] [-e K…] ID exe args`. `-e K` without a value
/// makes docker read it from its own environment, so values stay out of
/// argv. Paths go through the bind mounts.
final class DockerEnv extends ExecEnv {
  const DockerEnv({
    required this.cli,
    required this.container,
    required this.name,
    this.context,
    this.user,
    this.devcontainerFolder,
    this.mounts = const MountMap([]),
    this.hostName,
  });

  final String cli;

  /// The container id docker exec takes.
  final String container;
  final String name;

  /// The docker context it runs under; null for the current one.
  final String? context;

  /// `remoteUser` from the dev container's metadata.
  final String? user;

  /// The host folder a dev container was made for
  /// (`devcontainer.local_folder`).
  final String? devcontainerFolder;
  final MountMap mounts;

  /// How the host is reached from inside (`host.docker.internal` on Docker
  /// Desktop, OrbStack and Colima); null when unknown.
  final String? hostName;

  @override
  String get id => devcontainerFolder != null
      ? 'devcontainer:$devcontainerFolder'
      : context == null
      ? 'docker:$name'
      : 'docker:$context/$name';

  @override
  EnvKind get kind => EnvKind.container;

  @override
  String get label {
    final folder = devcontainerFolder;
    if (folder == null) return '$name (Container)';
    final parts = folder.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty);
    return '${parts.isEmpty ? folder : parts.last} (Dev container)';
  }

  @override
  WrappedCommand wrap(String executable, List<String> args, {String? cwd, Map<String, String> env = const {}}) {
    checkEnvNames(env);
    return (
      executable: cli,
      args: [
        if (context != null) ...['--context', context!],
        'exec',
        '-i',
        if (user != null) ...['-u', user!],
        if (cwd != null) ...['-w', cwd],
        for (final k in env.keys) ...['-e', k],
        container,
        executable,
        ...args,
      ],
      environment: env,
    );
  }

  @override
  String? toEnvPath(String hostPath) => mounts.toEnv(hostPath);

  @override
  String? toHostPath(String envPath) => mounts.toHost(envPath);

  @override
  Uri? hostUrl(Uri loopback) => _viaHostName(loopback, hostName);
}

/// Notes "read-only inside" when the user's home is shared without write
/// access (Lima's default).
String? _readOnlyHome(MountMap mounts, String home) => mounts.writableAt(home) == false
    ? 'Your home folder is read-only inside, so edits to projects there will fail.'
    : null;

/// A Lima VM: `limactl shell --workdir CWD NAME [env K=V…] exe args`. Lima
/// quotes each argument itself and runs them under the guest's login shell.
final class LimaEnv extends ExecEnv {
  const LimaEnv({
    required this.cli,
    required this.name,
    required this.home,
    this.running = true,
    this.mounts = const MountMap([]),
  });

  final String cli;
  final String name;

  /// The host user's home (for the read-only note).
  final String home;
  @override
  final bool running;
  final MountMap mounts;

  @override
  String get id => 'lima:$name';

  @override
  EnvKind get kind => EnvKind.vm;

  @override
  String get label => '$name (Lima)';

  @override
  String? get note => _readOnlyHome(mounts, home);

  @override
  WrappedCommand wrap(String executable, List<String> args, {String? cwd, Map<String, String> env = const {}}) => (
    executable: cli,
    args: [
      'shell',
      if (cwd != null) ...['--workdir', cwd],
      name,
      ..._envArgs(env),
      executable,
      ...args,
    ],
    environment: const {},
  );

  @override
  String? toEnvPath(String hostPath) => mounts.toEnv(hostPath);

  @override
  String? toHostPath(String envPath) => mounts.toHost(envPath);

  @override
  Uri? hostUrl(Uri loopback) => _viaHostName(loopback, 'host.lima.internal');
}

/// An OrbStack machine: `orb -m M sh -c 'cd CWD && exec …'` (or `orbctl run
/// -m M …` when only orbctl is there). The Mac's /Users, /Volumes, /private
/// and /tmp are at the same paths inside, everything else under /mnt/mac;
/// the machine's own files are at `~/OrbStack/<machine>` on the Mac.
final class OrbEnv extends ExecEnv {
  const OrbEnv({
    required this.cli,
    required this.machine,
    required this.home,
    this.running = true,
    this.viaOrbctl = false,
  });

  final String cli;
  final String machine;
  final String home;
  @override
  final bool running;

  /// [cli] is orbctl, which needs `run` first.
  final bool viaOrbctl;

  static const _same = ['/Users', '/Volumes', '/private', '/tmp'];

  @override
  String get id => 'orb:$machine';

  @override
  EnvKind get kind => EnvKind.vm;

  @override
  String get label => '$machine (OrbStack)';

  @override
  WrappedCommand wrap(String executable, List<String> args, {String? cwd, Map<String, String> env = const {}}) => (
    executable: cli,
    args: [
      if (viaOrbctl) 'run',
      '-m',
      machine,
      'sh',
      '-c',
      bridgeScript(executable, args, cwd: cwd, env: env),
    ],
    environment: const {},
  );

  @override
  String? toEnvPath(String hostPath) {
    if (!hostPath.startsWith('/') || hostPath.split('/').contains('..')) return null;
    // The machine's own files first: they are under /Users too.
    final own = '$home/OrbStack/$machine';
    if (hostPath == own) return '/';
    if (hostPath.startsWith('$own/')) return hostPath.substring(own.length);
    if (_same.any((p) => hostPath == p || hostPath.startsWith('$p/'))) return hostPath;
    return '/mnt/mac$hostPath';
  }

  @override
  String? toHostPath(String envPath) {
    if (!envPath.startsWith('/') || envPath.split('/').contains('..')) return null;
    if (_same.any((p) => envPath == p || envPath.startsWith('$p/'))) return envPath;
    if (envPath == '/mnt/mac') return '/';
    if (envPath.startsWith('/mnt/mac/')) return envPath.substring('/mnt/mac'.length);
    return '$home/OrbStack/$machine${envPath == '/' ? '' : envPath}';
  }

  @override
  Uri? hostUrl(Uri loopback) => _viaHostName(loopback, 'host.orb.internal');
}

/// A Multipass VM: `multipass exec NAME --working-directory CWD -- [env
/// K=V…] exe args`. Paths go through `multipass mount` shares.
final class MultipassEnv extends ExecEnv {
  const MultipassEnv({required this.cli, required this.name, this.running = true, this.mounts = const MountMap([])});

  final String cli;
  final String name;
  @override
  final bool running;
  final MountMap mounts;

  @override
  String get id => 'multipass:$name';

  @override
  EnvKind get kind => EnvKind.vm;

  @override
  String get label => '$name (Multipass)';

  @override
  WrappedCommand wrap(String executable, List<String> args, {String? cwd, Map<String, String> env = const {}}) => (
    executable: cli,
    args: [
      'exec',
      name,
      if (cwd != null) ...['--working-directory', cwd],
      '--',
      ..._envArgs(env),
      executable,
      ...args,
    ],
    environment: const {},
  );

  @override
  String? toEnvPath(String hostPath) => mounts.toEnv(hostPath);

  @override
  String? toHostPath(String envPath) => mounts.toHost(envPath);

  // No name for the host inside; the MCP host would need a bridged address.
  @override
  Uri? hostUrl(Uri loopback) => _viaHostName(loopback, null);
}

/// A Colima VM (its containers come through Docker): `colima ssh -p P --
/// sh -c 'cd CWD && exec …'`. Colima shares the user's home, writable.
final class ColimaEnv extends ExecEnv {
  const ColimaEnv({required this.cli, required this.profile, required this.home, this.running = true});

  final String cli;
  final String profile;
  final String home;
  @override
  final bool running;

  MountMap get _mounts => MountMap([(host: home, env: home, writable: true)]);

  @override
  String get id => 'colima:$profile';

  @override
  EnvKind get kind => EnvKind.vm;

  @override
  String get label => '$profile (Colima)';

  @override
  WrappedCommand wrap(String executable, List<String> args, {String? cwd, Map<String, String> env = const {}}) => (
    executable: cli,
    args: [
      'ssh',
      '-p',
      profile,
      '--',
      'sh',
      '-c',
      bridgeScript(executable, args, cwd: cwd, env: env),
    ],
    environment: const {},
  );

  @override
  String? toEnvPath(String hostPath) => _mounts.toEnv(hostPath);

  @override
  String? toHostPath(String envPath) => _mounts.toHost(envPath);

  @override
  Uri? hostUrl(Uri loopback) => _viaHostName(loopback, 'host.lima.internal');
}

/// A remote the user added: an alias from `~/.ssh/config`, or user@host with
/// an optional port. Keys and the agent only: never a password prompt.
final class SshRemote {
  const SshRemote.alias(String this.alias) : user = null, host = null, port = null;
  const SshRemote.host({required String this.user, required String this.host, this.port}) : alias = null;

  final String? alias;
  final String? user;
  final String? host;
  final int? port;

  /// What ssh connects to.
  String get destination => alias ?? '$user@$host';

  /// Why it can't be used, in plain words, or null.
  String? get problem {
    final a = alias;
    if (a != null) return safeName(a) && !a.contains('@') ? null : "That isn't an ssh alias.";
    if (!safeName(user!) || user!.contains('@')) return "That isn't a user name.";
    if (!safeName(host!) || host!.contains('@')) return "That isn't a host name.";
    final p = port;
    if (p != null && (p < 1 || p > 65535)) return 'The port must be between 1 and 65535.';
    return null;
  }

  String get key => alias ?? '$user@$host${port == null ? '' : ':$port'}';

  Map<String, Object?> toJson() =>
      alias != null ? {'alias': alias} : {'user': user, 'host': host, if (port != null) 'port': port};

  static SshRemote? fromJson(Object? json) {
    if (json is! Map) return null;
    final alias = json['alias'];
    if (alias is String) return SshRemote.alias(alias);
    final user = json['user'], host = json['host'], port = json['port'];
    if (user is! String || host is! String) return null;
    return SshRemote.host(user: user, host: host, port: port is int ? port : null);
  }

  @override
  bool operator ==(Object other) => other is SshRemote && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// An ssh remote: `ssh -T -o BatchMode=yes -o ConnectTimeout=5 [-p N] --
/// DEST LINE`. ssh hands the remote command to the remote user's login
/// shell, which may be fish or csh: their quoting differs from sh's (csh
/// allows no newline inside quotes, fish reads `\'` and `\\` there). So the
/// line is `exec /bin/sh -c 'eval "$(printf %s B64 | base64 -d)"'`, with
/// the `cd CWD && exec …` script base64-encoded: no backslash, newline or
/// quote inside the quotes, read the same by sh, fish and csh. stdin stays
/// the program's. The project lives on the remote: no path maps either way.
final class SshEnv extends ExecEnv {
  const SshEnv({required this.cli, required this.remote});

  final String cli;
  final SshRemote remote;

  @override
  String get id => 'ssh:${remote.key}';

  @override
  EnvKind get kind => EnvKind.ssh;

  @override
  String get label => '${remote.alias ?? remote.host} (SSH)';

  @override
  WrappedCommand wrap(String executable, List<String> args, {String? cwd, Map<String, String> env = const {}}) {
    if (remote.problem != null) throw ArgumentError.value(remote.key, 'remote', remote.problem);
    return (
      executable: cli,
      args: [
        '-T',
        '-o',
        'BatchMode=yes',
        '-o',
        'ConnectTimeout=5',
        if (remote.port != null) ...['-p', '${remote.port}'],
        '--',
        remote.destination,
        sshRemoteLine(bridgeScript(executable, args, cwd: cwd, env: env)),
      ],
      environment: const {},
    );
  }

  @override
  String? toEnvPath(String hostPath) => null;

  @override
  String? toHostPath(String envPath) => null;

  @override
  Uri? hostUrl(Uri loopback) => _viaHostName(loopback, null);
}

/// [script] as one remote command line any login shell parses the same way
/// (see [SshEnv]).
String sshRemoteLine(String script) =>
    "exec /bin/sh -c 'eval \"\$(printf %s ${base64.encode(utf8.encode(script))} | base64 -d)\"'";
