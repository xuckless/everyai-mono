// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../process/process_model.dart';
import 'local_backend.dart';

LocalBackend createLocalBackend() => _NoLocalBackend();

final class _NoLocalBackend implements LocalBackend {
  static const _why = 'The built-in server runs in the desktop app.';

  @override
  Future<LocalBackendInfo?> ensureStarted() async => null;

  @override
  BackendPhase get phase => const BackendUnavailable(_why);

  @override
  String? get problem => _why;

  @override
  bool get running => false;

  @override
  Future<KillOutcome> stop() async => const Ended([]);

  @override
  Future<KillOutcome> close({Duration unloadWithin = const Duration(seconds: 4)}) async => const Ended([]);
}
