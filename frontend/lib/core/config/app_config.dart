import 'package:flutter/foundation.dart';

/// Build-time configuration, supplied with
/// `flutter run --dart-define-from-file=config/dev.json`.
///
/// Only public values belong here: everything passed through dart-define is
/// compiled into the app binary. Provider API keys stay on the backend.
@immutable
final class AppConfig {
  const AppConfig({required this.apiBaseUrl, required this.devTools, required this.sseEnabled});

  factory AppConfig.fromEnvironment() {
    const url = String.fromEnvironment('API_BASE_URL');
    return AppConfig(
      apiBaseUrl: Uri.parse(url.isEmpty ? _defaultBaseUrl() : url),
      devTools: const bool.fromEnvironment('DEV_TOOLS', defaultValue: kDebugMode),
      sseEnabled: const bool.fromEnvironment('SSE_ENABLED', defaultValue: true),
    );
  }

  /// Backend origin (backend-exp serves `/v1` under it), e.g. `http://localhost:8080`.
  final Uri apiBaseUrl;

  /// Developer switches in Settings → Developer (the backend's `DEV_AUTH`
  /// routes, such as where Claude calls go). On in debug builds.
  final bool devTools;

  /// Stream chat over SSE (`/v1/chat/stream`). Off only for debugging.
  final bool sseEnabled;

  /// The Android emulator reaches the host machine at 10.0.2.2, not localhost.
  static String _defaultBaseUrl() =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android ? 'http://10.0.2.2:8080' : 'http://localhost:8080';
}
