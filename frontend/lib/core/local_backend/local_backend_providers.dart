// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../net/api_client.dart';
import '../net/http_client.dart';
import '../process/process_model.dart';
import 'local_backend.dart';

/// The bundled server; stopped when the app quits (provider disposal doesn't run then).
final localBackendProvider = Provider<LocalBackend>((ref) {
  final backend = createLocalBackend();
  // Quitting stops it through appQuitProvider (app/app_quit.dart). Here (a test's container, a hot
  // restart) the stop's outcome is logged when it isn't a checked end.
  ref.onDispose(() {
    backend.stop().then(
      (o) => o is Ended ? null : debugPrint('NOT CLOSED: the bundled server at dispose: $o'),
      onError: (Object e) => debugPrint('NOT CLOSED: the bundled server at dispose: the stop failed: $e'),
    );
  });
  return backend;
});

/// Clients for the bundled server: [client] starts it on first use, and
/// makes a new client when a restart changed its port and token.
final localApiProvider = Provider<LocalApi>((ref) {
  final api = LocalApi(ref.watch(localBackendProvider));
  ref.onDispose(api.close);
  return api;
});

final class LocalApi {
  LocalApi(this.backend);

  final LocalBackend backend;
  ApiClient? _client;
  String? _token;

  /// Null when there is no bundled server ([LocalBackend.problem] says why).
  Future<ApiClient?> client() async {
    final info = await backend.ensureStarted();
    if (info == null) return null;
    if (_client != null && _token == info.token) return _client;
    _client?.close();
    _token = info.token;
    return _client = ApiClient(
      baseUrl: info.baseUrl,
      client: createPlatformHttpClient(userAgent: 'EveryAI/0.1'),
      defaultHeaders: {LocalBackendInfo.tokenHeader: info.token},
      acceptsProviderKeys: true,
      waitForServer: true,
    );
  }

  void close() {
    _client?.close();
    _client = null;
  }
}
