// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'child_processes.dart';

void track(int pid, {required String label, required String executable, required Future<int> exited}) {}
ChildPhase? phaseOf(int pid) => null;
Future<void> stop(int pid) async {}
Future<void> stopAll() async {}
Map<int, String> get tracked => const {};
