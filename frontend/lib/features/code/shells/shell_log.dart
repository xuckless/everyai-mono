// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:typed_data';

import 'shell_log_stub.dart' if (dart.library.io) 'shell_log_io.dart' as impl;

/// The whole output a shell log holds so far (its older segment first), or
/// empty when there is none.
Future<Uint8List> readShellLog(String path) => impl.readShellLog(path);

/// [readShellLog] at once (a tab opening reads and subscribes in the same step).
Uint8List readShellLogSync(String path) => impl.readShellLogSync(path);
