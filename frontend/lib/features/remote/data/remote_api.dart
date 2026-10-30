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

/// A host on the account.
typedef RemoteHostInfo = ({String id, String name, String platform, bool online, List<RemoteDevice> devices});

/// The backend's `/v1/remote` REST endpoints (see AGENTS.md).
final class RemoteApi {
  const RemoteApi(this._api, {required this.authenticated});

  final ApiClient _api;

  /// False with `DEV_SKIP_AUTH` (the backend's dev user answers).
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

  Future<void> deleteHost(String id) => _api.delete('v1/remote/hosts/$id', authenticated: authenticated);

  Future<void> deleteDevice(String id) => _api.delete('v1/remote/devices/$id', authenticated: authenticated);

  Future<PairingCode> newCode(String hostId) async {
    final r = await _api.postJson('v1/remote/pair', {'host_id': hostId}, authenticated: authenticated);
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

  /// `open`, `pending`, `approved`, `denied` or `expired`.
  Future<String> pairingStatus(String pairingId) async {
    final r = await _api.getJson('v1/remote/pair/$pairingId', authenticated: authenticated);
    return r['status'] as String? ?? 'expired';
  }

  Future<void> decide(String pairingId, {required bool approve, required String hostToken}) => _api.postJson(
    'v1/remote/pair/$pairingId/${approve ? 'approve' : 'deny'}',
    const {},
    authenticated: authenticated,
    headers: {'X-Remote-Host-Token': hostToken},
  );
}
