// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/preferences.dart';
import 'bridges.dart';
import 'discovery.dart';
import 'environment_io_stub.dart' if (dart.library.io) 'environment_io_io.dart' as io;
import 'environment_scan.dart';
import 'exec_env.dart';

/// This computer's processes and files, for discovery and scans (tests
/// override it).
final environmentIoProvider = Provider<EnvironmentIo>((ref) => io.platformEnvironmentIo());

/// The ssh remotes the user added (Preferences [sshRemotesKey]).
final sshRemotesProvider = NotifierProvider<SshRemotes, List<SshRemote>>(SshRemotes.new);

final class SshRemotes extends Notifier<List<SshRemote>> {
  @override
  List<SshRemote> build() => readSshRemotes(ref.read(preferencesProvider)[sshRemotesKey]);

  void _set(List<SshRemote> next) {
    state = next;
    ref.read(preferencesProvider)[sshRemotesKey] = encodeSshRemotes(next);
  }

  /// Adds [remote] unless it's there already or [SshRemote.problem] objects.
  void add(SshRemote remote) {
    if (remote.problem != null || state.contains(remote)) return;
    _set([...state, remote]);
  }

  void remove(SshRemote remote) => _set([...state.where((r) => r != remote)]);
}

/// Every environment found on this computer and what went wrong per kind.
/// Looked for when first read (the Code views), kept in memory until
/// invalidated ("Check again").
final environmentDiscoveryProvider = FutureProvider<EnvDiscovery>(
  (ref) => discoverEnvironments(ref.watch(environmentIoProvider), ssh: ref.watch(sshRemotesProvider)),
);

/// Every environment found, the host first, then WSL distros, containers,
/// VMs and ssh remotes.
final environmentsProvider = FutureProvider<List<ExecEnv>>(
  (ref) async => (await ref.watch(environmentDiscoveryProvider.future)).environments,
);

/// The commands each environment is scanned for. The drivers' list goes here
/// at integration.
final environmentScanCommandsProvider = Provider<List<String>>((ref) => defaultScanCommands);

/// What's installed inside the environment with this id, looked for once and
/// kept in memory. "Check again" is `ref.invalidate(environmentScanProvider(id))`,
/// plus `ref.invalidate(environmentDiscoveryProvider)` (a container made
/// again has a new id). The list is read, not watched, so finding the
/// environments again doesn't scan every one of them again.
final environmentScanProvider = FutureProvider.family<EnvScan, String>((ref, id) async {
  final env = environmentById(await ref.read(environmentsProvider.future), id);
  if (env == null) return const EnvScan(problem: "That environment isn't here any more.");
  return scanEnvironment(
    env,
    commands: ref.watch(environmentScanCommandsProvider),
    run: ref.watch(environmentIoProvider).run,
  );
});

/// The environment with [id], or null when it's gone (a removed distro, a
/// stopped dev container). Never the host instead: a project set to run in
/// one must not run its commands here.
ExecEnv? environmentById(List<ExecEnv> all, String id) {
  for (final e in all) {
    if (e.id == id) return e;
  }
  return null;
}
