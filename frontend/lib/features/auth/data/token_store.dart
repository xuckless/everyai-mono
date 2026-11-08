import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../../../core/config/app_config.dart';
import '../../../core/net/api_client.dart';
import '../../../core/providers.dart';

/// Session tokens. The access token lives only in memory. The refresh token
/// lives in the OS keychain/keystore (Keychain, Keystore, libsecret, DPAPI;
/// encrypted IndexedDB on the web).
final class TokenStore implements AccessTokenSource {
  TokenStore(this._config);

  final AppConfig _config;
  // macOS: the data-protection keychain needs the keychain-sharing entitlement,
  // which requires a signed build. Unsigned debug builds use the legacy keychain.
  static const _storage = FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: !kDebugMode));
  static const _refreshKey = 'everyai.refresh_token';

  /// The backend issues 15-minute access tokens. Refresh a little early.
  static const accessTokenLifetime = Duration(minutes: 14);

  String? _accessToken;
  DateTime? _accessExpiry;
  Future<String?>? _refreshing;

  /// Bumped by [save] and [clear]: a refresh that was on its way when the
  /// session changed (a sign-out, a new sign-in) keeps nothing it got back,
  /// so a rotated refresh token can't come back after [clear].
  int _epoch = 0;

  final _ended = StreamController<void>.broadcast();

  /// Fires when the server refused the stored refresh token (revoked
  /// elsewhere, expired): the session is gone and the tokens were cleared.
  Stream<void> get sessionEnded => _ended.stream;

  /// The refresh under way, if any; sign-out waits for it so it revokes the
  /// newest refresh token.
  Future<void> settled() async {
    try {
      await _refreshing;
    } on Object {
      // Its caller sees the error.
    }
  }

  bool get hasValidAccessToken => _accessToken != null && DateTime.now().isBefore(_accessExpiry!);

  Future<String?> readRefreshToken() => _storage.read(key: _refreshKey);

  Future<void> save({required String accessToken, required String refreshToken}) async {
    _epoch++;
    _setAccess(accessToken);
    await _storage.write(key: _refreshKey, value: refreshToken);
  }

  Future<void> clear() async {
    _epoch++;
    _accessToken = null;
    _accessExpiry = null;
    await _storage.delete(key: _refreshKey);
  }

  @override
  Future<String?> accessToken() async => hasValidAccessToken ? _accessToken : refreshAccessToken();

  /// Exchanges the stored refresh token for a new access token. Concurrent
  /// callers share one in-flight refresh.
  @override
  Future<String?> refreshAccessToken() => _refreshing ??= _refresh().whenComplete(() => _refreshing = null);

  Future<String?> _refresh() async {
    final epoch = _epoch;
    final refresh = await readRefreshToken();
    if (refresh == null || epoch != _epoch) return null;
    // A bare client: going through ApiClient would recurse into this source.
    final client = http.Client();
    try {
      final res = await client
          .post(
            _config.apiBaseUrl.resolve('v1/auth/refresh'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'refresh_token': refresh}),
          )
          .timeout(ApiClient.jsonTimeout);
      // Signed out or in again meanwhile: this answer is the old session's.
      if (epoch != _epoch) return null;
      if (res.statusCode == 401) {
        await clear();
        _ended.add(null);
        return null;
      }
      if (res.statusCode != 200) return null;
      final json = jsonDecode(res.body);
      if (json case {'access_token': final String access}) {
        _setAccess(access);
        // Refresh tokens rotate: the old one is spent once used.
        if (json case {'refresh_token': final String next}) await _storage.write(key: _refreshKey, value: next);
        return access;
      }
      return null;
    } on Object {
      return null;
    } finally {
      client.close();
    }
  }

  void dispose() => unawaited(_ended.close());

  void _setAccess(String token) {
    _accessToken = token;
    _accessExpiry = DateTime.now().add(accessTokenLifetime);
  }
}

final tokenStoreProvider = Provider<TokenStore>((ref) {
  final store = TokenStore(ref.watch(appConfigProvider));
  ref.onDispose(store.dispose);
  return store;
});
