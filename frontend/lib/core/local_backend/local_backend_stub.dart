// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'local_backend.dart';

LocalBackend createLocalBackend() => _NoLocalBackend();

final class _NoLocalBackend implements LocalBackend {
  @override
  Future<LocalBackendInfo?> ensureStarted() async => null;

  @override
  String? get problem => 'The built-in server runs in the desktop app.';

  @override
  bool get running => false;

  @override
  Future<void> stop() async {}
}
