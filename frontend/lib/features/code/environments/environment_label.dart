// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'exec_env.dart';

/// A harness's name where it runs: "Claude Code · Ubuntu (WSL)". On this
/// computer it's the name alone, so nothing changes for the common case.
String harnessLabel(String name, ExecEnv? env) => env == null || env.isHost ? name : '$name · ${env.label}';
