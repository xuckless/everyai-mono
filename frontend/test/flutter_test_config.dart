// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';

import 'package:every_ai/core/motion/motion.dart';

/// Every test: ambient loops (breathing dots, shimmer, spinners) stay still so
/// `pumpAndSettle` settles.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  Motion.ambient = false;
  await testMain();
}
