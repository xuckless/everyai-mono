import '../../../core/net/api_client.dart';
import '../../../core/net/api_error.dart';

/// What `POST /v1/auth/magic` answers.
typedef MagicAsk = ({String requestId, String secret, DateTime expiresAt});

/// A poll or code answer: the request's status, and the session tokens once
/// it is redeemed by this device.
typedef MagicAnswer = ({String status, String? accessToken, String? refreshToken});

/// The magic-link endpoints (backend-exp `magic.zig`). An interface so tests
/// answer without a server.
abstract interface class MagicApi {
  Future<MagicAsk> ask(String email, {required String deviceName});
  Future<MagicAnswer> poll(String requestId, String secret);

  /// Throws [WrongCode] for a wrong code, [ApiError] otherwise.
  Future<MagicAnswer> code(String requestId, String secret, String code);
}

/// The code was wrong. [dead]: that was the last try, ask for a new email.
final class WrongCode implements Exception {
  const WrongCode({required this.dead});
  final bool dead;
}

final class HttpMagicApi implements MagicApi {
  HttpMagicApi(this._api);
  final ApiClient _api;

  @override
  Future<MagicAsk> ask(String email, {required String deviceName}) async {
    final json = await _api.postJson('v1/auth/magic', {'email': email, 'device_name': deviceName});
    return switch (json) {
      {'request_id': final String id, 'request_secret': final String secret, 'expires_at': final int at} => (
        requestId: id,
        secret: secret,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(at * 1000),
      ),
      _ => throw const ProtocolError('Unexpected sign-in response.'),
    };
  }

  @override
  Future<MagicAnswer> poll(String requestId, String secret) async =>
      _answer(await _api.postJson('v1/auth/magic/poll', {'request_id': requestId, 'request_secret': secret}));

  @override
  Future<MagicAnswer> code(String requestId, String secret, String code) async {
    try {
      return _answer(
        await _api.postJson('v1/auth/magic/code', {'request_id': requestId, 'request_secret': secret, 'code': code}),
      );
    } on UnauthorizedError catch (e) {
      throw WrongCode(dead: e.code == 'magic_dead');
    } on HttpStatusError catch (e) {
      if (e.statusCode == 410) return (status: 'expired', accessToken: null, refreshToken: null);
      rethrow;
    }
  }

  static MagicAnswer _answer(Map<String, Object?> json) => (
    status: json['status'] is String ? json['status']! as String : 'pending',
    accessToken: switch (json['tokens']) {
      {'access_token': final String a} => a,
      _ => null,
    },
    refreshToken: switch (json['tokens']) {
      {'refresh_token': final String r} => r,
      _ => null,
    },
  );
}
