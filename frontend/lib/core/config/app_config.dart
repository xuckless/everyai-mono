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
      sseEnabled: const bool.fromEnvironment('SSE_ENABLED', defaultValue: true),
      googleServerClientId: const String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID'),
    );
  }

  /// Backend origin (backend-exp serves `/v1` under it), e.g. `http://localhost:8080`.
  final Uri apiBaseUrl;

  /// Skip sign-in and go straight to chat, as the backend's dev user (backend-exp
  /// with `DEV_AUTH=true` serves credential-less requests as `dev-user`).
  final bool devSkipAuth;

  /// Stream chat over SSE (`/v1/chat/stream`). Off only for debugging.
  final bool sseEnabled;

  /// OAuth web client ID that Google Sign-In uses to mint ID tokens for the backend.
  final String googleServerClientId;

  /// The Android emulator reaches the host machine at 10.0.2.2, not localhost.
  static String _defaultBaseUrl() =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android ? 'http://10.0.2.2:8080' : 'http://localhost:8080';
}
