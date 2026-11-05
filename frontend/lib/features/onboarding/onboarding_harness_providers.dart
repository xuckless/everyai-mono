// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../code/drivers/driver_registry.dart';
import '../code/environments/exec_env.dart';
import 'domain/harness_rows.dart';

/// What the setup step and Settings → Harnesses list: every check, per environment. Host only for now; the
/// environments lane reads each environment's scan here. Empty while the first check runs.
final harnessEnvStatusesProvider = Provider<List<EnvStatus>>((ref) {
  final statuses = ref.watch(driverStatusesProvider).value;
  if (statuses == null) return const [];
  return [for (final e in statuses.entries) (env: HostEnv.instance, driverId: e.key, status: e.value)];
});

/// The line the Git for Windows notice shows.
const gitForWindowsInstallLine = 'winget install --id Git.Git -e';
