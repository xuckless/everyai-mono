// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'discovery.dart';

/// No processes here (web): only the host is found.
EnvironmentIo platformEnvironmentIo() => EnvironmentIo(
  run: (exe, args, {timeout = Duration.zero, environment = const {}}) async => null,
  which: (_) async => null,
  os: HostOs.other,
);
