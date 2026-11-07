// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'local_backend_stub.dart' if (dart.library.io) 'local_backend_io.dart' as impl;

/// The EveryAI server bundled in the desktop app (backend-exp in local mode):
/// it runs chats on local models and on the user's own keys, so neither goes
/// through our deployed server. Loopback only; every request carries
/// [token] in `X-EveryAI-Local`.
final class LocalBackendInfo {
  const LocalBackendInfo({required this.baseUrl, required this.token});

  final Uri baseUrl;
  final String token;

  static const tokenHeader = 'X-EveryAI-Local';
}

/// Starts it (once per app run), restarts it when it dies, stops it on quit.
abstract interface class LocalBackend {
  /// The running server, started on first use. Null when this build has no
  /// bundled server (web, phones, a dev run without `tool/build_local_backend.sh`);
  /// [problem] then says why.
  Future<LocalBackendInfo?> ensureStarted();

  String? get problem;

  /// Whether it is up now (without starting it).
  bool get running;

  Future<void> stop();
}

LocalBackend createLocalBackend() => impl.createLocalBackend();
