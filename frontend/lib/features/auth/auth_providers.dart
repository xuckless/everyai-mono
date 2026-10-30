import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../../core/net/api_client.dart';
import '../../core/net/api_error.dart';
import '../../core/providers.dart';
import '../code/gateway_key.dart';
import '../remote/remote_providers.dart' show pairedHostsProvider, remoteHostingProvider;
import 'data/token_store.dart';
import 'domain/auth_state.dart';

final authProvider = NotifierProvider<AuthController, AuthState>(AuthController.new);

final class AuthController extends Notifier<AuthState> {
  TokenStore get _tokens => ref.read(tokenStoreProvider);
  ApiClient get _api => ref.read(apiClientProvider);

  @override
  AuthState build() {
    if (ref.watch(appConfigProvider).devSkipAuth) return const Bypassed();
    unawaited(_restore());
    return const Restoring();
  }

  Future<void> _restore() async {
    final token = await _tokens.refreshAccessToken();
    if (!ref.mounted) return;
    state = token == null ? const SignedOut() : const SignedIn();
  }

  Future<void> signIn({required String email, required String password}) => _authenticate(
    AuthMethod.password,
    () => _api.postJson('v1/auth/login', {'email': email.trim(), 'password': password}),
  );

  Future<void> signUp({required String name, required String email, required String password}) => _authenticate(
    AuthMethod.signUp,
    () => _api.postJson('v1/auth/signup', {'name': name.trim(), 'email': email.trim(), 'password': password}),
  );

  /// The backend accepts Google ID tokens minted for its iOS, Android or web
  /// client IDs. Desktop has no native Google flow yet.
  static bool get googleSupported =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android);

  Future<void> signInWithGoogle() => _authenticate(AuthMethod.google, () async {
    final google = GoogleSignIn.instance;
    await google.initialize(serverClientId: _nonEmpty(ref.read(appConfigProvider).googleServerClientId));
    final account = await google.authenticate();
    final idToken = account.authentication.idToken;
    if (idToken == null) throw const ProtocolError('Google did not return an ID token.');
    return _api.postJson('v1/auth/google', {'token': idToken});
  });

  Future<void> signOut() async {
    // Remote hosting and pairings belong to this account too. They go
    // first, while the backend still takes this account's calls.
    await _leaveRemote();
    final refresh = await _tokens.readRefreshToken();
    if (refresh != null) {
      unawaited(_api.postJson('v1/auth/logout', {'refresh_token': refresh}).then((_) {}, onError: (_) {}));
    }
    await _tokens.clear();
    // The Code gateway key belongs to this account; the next user mints their own.
    try {
      await ref.read(gatewayKeysProvider).clear();
    } on Object {
      // No keychain (or no preferences in a test): nothing was kept.
    }
    if (ref.read(appConfigProvider).devSkipAuth) return;
    state = const SignedOut();
  }

  /// Stops hosting and drops this device's pairings: the next account to
  /// sign in here must not drive this computer for the old one's devices,
  /// nor reach the old account's hosts.
  Future<void> _leaveRemote() async {
    try {
      await ref.read(remoteHostingProvider.notifier).signedOut();
    } on Object {
      // No keychain (a test): nothing was kept.
    }
    try {
      await ref.read(pairedHostsProvider.notifier).signedOut();
    } on Object {
      // Likewise.
    }
  }

  Future<void> _authenticate(AuthMethod method, Future<Map<String, Object?>> Function() call) async {
    if (state is Authenticating) return;
    state = Authenticating(method);
    try {
      final json = await call();
      if (json case {'access_token': final String access, 'refresh_token': final String refresh}) {
        await _tokens.save(accessToken: access, refreshToken: refresh);
        if (ref.mounted) state = const SignedIn();
      } else {
        throw const ProtocolError('Unexpected sign-in response.');
      }
    } on ApiError catch (e) {
      if (ref.mounted) state = SignedOut(error: e is UnauthorizedError ? 'Wrong email or password.' : e.message);
    } on GoogleSignInException catch (e) {
      if (!ref.mounted) return;
      state = e.code == GoogleSignInExceptionCode.canceled
          ? const SignedOut()
          : SignedOut(error: e.description ?? 'Google sign-in failed.');
    }
  }

  static String? _nonEmpty(String s) => s.isEmpty ? null : s;
}
