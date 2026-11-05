// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../drivers/driver.dart';
import '../drivers/driver_registry.dart';
import 'environment_providers.dart';

/// Whether each harness can run inside the environment with this id, by
/// driver id. The host's is [driverStatusesProvider]. Inside another one it
/// asks each driver bound there (its CLI comes from the environment's scan,
/// looked for once), so a harness found only in a WSL distro is offered for
/// projects that run there. Empty when the environment is gone: nothing is
/// offered on a guess. Invalidate it, with [environmentScanProvider], to
/// check again.
final driverStatusesInProvider = FutureProvider.family<Map<String, DriverStatus>, String>((ref, envId) async {
  if (envId == 'host') return ref.watch(driverStatusesProvider.future);
  final env = environmentById(await ref.watch(environmentsProvider.future), envId);
  if (env == null) return const {};
  final registry = ref.watch(driverRegistryProvider);
  final drivers = [for (final d in registry.listed) ?registry.resolve(d.info.id, env: env)];
  final found = await Future.wait([
    for (final d in drivers)
      () async {
        try {
          return await d.detect();
        } on Object catch (e) {
          return DriverStatus(problem: "Couldn't check: $e");
        }
      }(),
  ]);
  return {for (final (i, d) in drivers.indexed) d.info.id: found[i]};
});

/// Looks for the environments and what is installed in each again (a distro
/// was added, a CLI installed). The list shows "Looking…" meanwhile.
void rescanEnvironments(WidgetRef ref) {
  ref.invalidate(localDiscoveryProvider);
  ref.invalidate(environmentScanProvider);
  ref.invalidate(driverStatusesInProvider);
}
