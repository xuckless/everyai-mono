import '../../../core/net/api_client.dart';

/// A pairing code the host shows.
typedef PairingCode = ({String id, String code, DateTime expiresAt});

/// What redeeming a code returns to the device.
typedef Redeemed = ({
  String pairingId,
  String deviceId,
  String deviceToken,
  DateTime decideBy,
  String hostId,
  String hostName,
  String hostPlatform,
  String hostPublicKey,
});

/// A device paired with one of the account's hosts.
typedef RemoteDevice = ({String id, String hostId, String name, String publicKey, DateTime? lastSeen});

/// A host on the account (`GET /v1/remote/hosts` needs one).
typedef RemoteHostInfo = ({String id, String name, String platform, bool online, List<RemoteDevice> devices});

/// A webhook on the account (`GET /v1/hooks`); the secret is only in [RemoteApi.createHook]'s answer.
typedef HookInfo = ({String id, String name, String hostId, String url, DateTime? lastDelivery, int pending});

/// The backend's `/v1/remote` REST endpoints (see AGENTS.md) and `/v1/hooks` (backend-exp `hooks.zig`).
final class RemoteApi {
  const RemoteApi(this._api, {required this.authenticated});

  final ApiClient _api;

  /// Attaches the account token when signed in (remote works without one).
  final bool authenticated;

  static DateTime _time(Object? seconds) =>
      DateTime.fromMillisecondsSinceEpoch(((seconds as num?) ?? 0).toInt() * 1000);

  Future<({String id, String token})> registerHost({
    required String name,
    required String platform,
    required String publicKey,
  }) async {
    final r = await _api.postJson('v1/remote/hosts', {
      'name': name,
      'platform': platform,
      'public_key': publicKey,
    }, authenticated: authenticated);
    return (id: r['id']! as String, token: r['host_token']! as String);
  }

  Future<List<RemoteHostInfo>> hosts() async {
    final list = await _api.getJsonList('v1/remote/hosts', authenticated: authenticated);
    return [
      for (final h in list.whereType<Map<String, Object?>>())
        (
          id: h['id']! as String,
          name: h['name'] as String? ?? '',
          platform: h['platform'] as String? ?? '',
          online: h['online'] as bool? ?? false,
          devices: [
            for (final d in (h['devices'] as List<Object?>? ?? const []).whereType<Map<String, Object?>>())
              (
                id: d['id']! as String,
                hostId: d['host_id'] as String? ?? '',
                name: d['name'] as String? ?? '',
                publicKey: d['public_key'] as String? ?? '',
                lastSeen: d['last_seen_at'] == null ? null : _time(d['last_seen_at']),
              ),
          ],
        ),
    ];
  }

  /// Removes this desktop's host: only its own [hostToken] can.
  Future<void> deleteHost(String id, {required String hostToken}) =>
      _api.delete('v1/remote/hosts/$id', authenticated: authenticated, headers: {'X-Remote-Host-Token': hostToken});

  /// Unpairs a device: from its host ([hostToken]) or from the device itself ([deviceToken]).
  Future<void> deleteDevice(String id, {String? hostToken, String? deviceToken}) => _api.delete(
    'v1/remote/devices/$id',
    authenticated: authenticated,
    headers: {'X-Remote-Host-Token': ?hostToken, 'X-Remote-Device-Token': ?deviceToken},
  );

  /// A pairing code for this desktop's host: only its own [hostToken] mints one.
  Future<PairingCode> newCode(String hostId, {required String hostToken}) async {
    final r = await _api.postJson(
      'v1/remote/pair',
      {'host_id': hostId},
      authenticated: authenticated,
      headers: {'X-Remote-Host-Token': hostToken},
    );
    return (id: r['id']! as String, code: r['code']! as String, expiresAt: _time(r['expires_at']));
  }

  Future<Redeemed> redeem({required String code, required String deviceName, required String publicKey}) async {
    final r = await _api.postJson('v1/remote/pair/redeem', {
      'code': code,
      'device_name': deviceName,
      'public_key': publicKey,
    }, authenticated: authenticated);
    final host = r['host']! as Map<String, Object?>;
    return (
      pairingId: r['id']! as String,
      deviceId: r['device_id']! as String,
      deviceToken: r['device_token']! as String,
      decideBy: _time(r['decide_by']),
      hostId: host['id']! as String,
      hostName: host['name'] as String? ?? '',
      hostPlatform: host['platform'] as String? ?? '',
      hostPublicKey: host['public_key']! as String,
    );
  }

  /// `open`, `pending`, `approved`, `denied` or `expired`. Only the device
  /// that redeemed the code ([deviceToken]) or the host may ask.
  Future<String> pairingStatus(String pairingId, {required String deviceToken}) async {
    final r = await _api.getJson(
      'v1/remote/pair/$pairingId',
      authenticated: authenticated,
      headers: {'X-Remote-Device-Token': deviceToken},
    );
    return r['status'] as String? ?? 'expired';
  }

  /// Adds this desktop's host (made signed out) and its devices to the
  /// signed-in account. Throws a 409 [ApiError] when another account has it.
  Future<void> claimHost(String id, {required String hostToken}) => _api.postJson(
    'v1/remote/hosts/$id/claim',
    const {},
    authenticated: true,
    headers: {'X-Remote-Host-Token': hostToken},
  );

  Future<void> decide(String pairingId, {required bool approve, required String hostToken}) => _api.postJson(
    'v1/remote/pair/$pairingId/${approve ? 'approve' : 'deny'}',
    const {},
    authenticated: authenticated,
    headers: {'X-Remote-Host-Token': hostToken},
  );

  /// A webhook URL for [hostId]; the answer's secret is shown once.
  Future<({HookInfo hook, String secret})> createHook({
    required String name,
    required String hostId,
    required String hostToken,
  }) async {
    final r = await _api.postJson(
      'v1/hooks',
      {'name': name, 'host_id': hostId},
      authenticated: authenticated,
      headers: {'X-Remote-Host-Token': hostToken},
    );
    return (hook: _hook(r), secret: r['secret']! as String);
  }

  Future<List<HookInfo>> hooks() async {
    final list = await _api.getJsonList('v1/hooks', authenticated: authenticated);
    return [for (final h in list.whereType<Map<String, Object?>>()) _hook(h)];
  }

  /// Deletes one of this desktop's hooks ([hostToken] is its host's).
  Future<void> deleteHook(String id, {required String hostToken}) =>
      _api.delete('v1/hooks/$id', authenticated: authenticated, headers: {'X-Remote-Host-Token': hostToken});

  static HookInfo _hook(Map<String, Object?> h) => (
    id: h['id']! as String,
    name: h['name'] as String? ?? '',
    hostId: h['host_id'] as String? ?? '',
    url: h['url'] as String? ?? '',
    lastDelivery: h['last_delivery_at'] == null ? null : _time(h['last_delivery_at']),
    pending: (h['pending'] as num?)?.toInt() ?? 0,
  );
}
