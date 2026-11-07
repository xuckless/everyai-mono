// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'axe_install_stub.dart' if (dart.library.io) 'axe_install_io.dart' as impl;

/// AXe's program (EVERYAI_AXE, one EveryAI downloaded, or one on the PATH), or null.
String? axePath() => impl.axePath();

/// The program, downloaded first when there is none ([installAxe]); throws when that fails.
Future<String> ensureAxe({void Function(double progress)? onProgress}) => impl.ensureAxe(onProgress: onProgress);

/// Downloads the pinned AXe (see `axe_pin.dart`) into the app's data folder and checks its SHA-256. macOS only.
Future<String> installAxe({void Function(double progress)? onProgress}) => impl.installAxe(onProgress: onProgress);
