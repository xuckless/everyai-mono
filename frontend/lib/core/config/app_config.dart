import 'package:flutter/foundation.dart';

/// Build-time configuration, supplied with
/// `flutter run --dart-define-from-file=config/dev.json`.
///
/// Only public values belong here: everything passed through dart-define is
/// compiled into the app binary. Provider API keys stay on the backend.
@immutable
final class AppConfig {
  const AppConfig({
    required this.apiBaseUrl,
    required this.devSkipAuth,
    required this.sseEnabled,
    required this.googleServerClientId,
  });

  factory AppConfig.fromEnvironment() {
    const url = String.fromEnvironment('API_BASE_URL');
    return AppConfig(
      apiBaseUrl: Uri.parse(url.isEmpty ? _defaultBaseUrl() : url),
      devSkipAuth: const bool.fromEnvironment('DEV_SKIP_AUTH', defaultValue: true),
      sseEnabled: const bool.fromEnvironment('SSE_ENABLED'),
      googleServerClientId: const String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID'),
    );
  }

  /// Backend origin, e.g. `http://localhost:8000` or the Render deployment.
  final Uri apiBaseUrl;

  /// Skip sign-in and go straight to chat. On by default until the backend
  /// protects chat routes.
  final bool devSkipAuth;

  /// Use the streaming (SSE) chat endpoint instead of one-shot POSTs.
  final bool sseEnabled;

  /// OAuth web client ID that Google Sign-In uses to mint ID tokens for the backend.
  final String googleServerClientId;

  /// The Android emulator reaches the host machine at 10.0.2.2, not localhost.
  static String _defaultBaseUrl() =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android ? 'http://10.0.2.2:8000' : 'http://localhost:8000';
}
