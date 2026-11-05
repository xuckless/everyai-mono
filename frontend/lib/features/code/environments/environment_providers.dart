// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'exec_env.dart';

/// Every environment found on this computer, the host first. Seam: the
/// environments lane replaces the body with discovery (WSL, containers, VMs,
/// SSH remotes) and a per-environment cache.
final environmentsProvider = FutureProvider<List<ExecEnv>>((ref) async => const [HostEnv.instance]);

/// The environment with [id], or the host when it's gone.
ExecEnv environmentById(List<ExecEnv> all, String id) =>
    all.firstWhere((e) => e.id == id, orElse: () => HostEnv.instance);
