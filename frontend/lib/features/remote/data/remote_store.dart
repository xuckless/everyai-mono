import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../code/gateway_key.dart' show SecretStore;

/// This desktop as a remote host: registered with the backend once, then
/// turned on and off. Kept in the keychain (the token and private key are secrets).
@immutable
final class HostRegistration {
  const HostRegistration({
    required this.id,
    required this.name,
    required this.token,
    required this.privateKey,
    this.devices = const {},
    this.enabled = true,
  });

  final String id;
  final String name;

  /// The `rh_` token (shown once by the backend).
  final String token;

  /// Base64 X25519 private key.
  final String privateKey;

  /// Approved devices: id → base64 public key, as approved here. A device
  /// the relay announces with another key is refused.
  final Map<String, String> devices;
  final bool enabled;

  HostRegistration copyWith({Map<String, String>? devices, bool? enabled}) => HostRegistration(
    id: id,
    name: name,
    token: token,
    privateKey: privateKey,
    devices: devices ?? this.devices,
    enabled: enabled ?? this.enabled,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'token': token,
    'private_key': privateKey,
    'devices': devices,
    'enabled': enabled,
  };

  static HostRegistration fromJson(Map<String, Object?> j) => HostRegistration(
    id: j['id']! as String,
    name: j['name'] as String? ?? '',
    token: j['token']! as String,
    privateKey: j['private_key']! as String,
    devices: {
      for (final e in (j['devices'] as Map<String, Object?>? ?? const {}).entries)
        if (e.value case final String key) e.key: key,
    },
    enabled: j['enabled'] as bool? ?? true,
  );
}

/// A host this device paired with (or is waiting on).
@immutable
final class PairedHost {
  const PairedHost({
    required this.hostId,
    required this.name,
    required this.platform,
    required this.hostPublicKey,
    required this.deviceId,
    required this.deviceToken,
    required this.privateKey,
    required this.pairingId,
    this.approved = false,
  });

  final String hostId;
  final String name;
  final String platform;

  /// Base64 X25519 key of the host, checked at pairing.
  final String hostPublicKey;
  final String deviceId;

  /// The `rd_` token (shown once by the backend).
  final String deviceToken;

  /// This device's base64 X25519 private key for this host.
  final String privateKey;
  final String pairingId;

  /// The host approved this device.
  final bool approved;

  PairedHost approve() => PairedHost(
    hostId: hostId,
    name: name,
    platform: platform,
    hostPublicKey: hostPublicKey,
    deviceId: deviceId,
    deviceToken: deviceToken,
    privateKey: privateKey,
    pairingId: pairingId,
    approved: true,
  );

  Map<String, Object?> toJson() => {
    'host_id': hostId,
    'name': name,
    'platform': platform,
    'host_public_key': hostPublicKey,
    'device_id': deviceId,
    'device_token': deviceToken,
    'private_key': privateKey,
    'pairing_id': pairingId,
    'approved': approved,
  };

  static PairedHost fromJson(Map<String, Object?> j) => PairedHost(
    hostId: j['host_id']! as String,
    name: j['name'] as String? ?? '',
    platform: j['platform'] as String? ?? '',
    hostPublicKey: j['host_public_key']! as String,
    deviceId: j['device_id']! as String,
    deviceToken: j['device_token']! as String,
    privateKey: j['private_key']! as String,
    pairingId: j['pairing_id'] as String? ?? '',
    approved: j['approved'] as bool? ?? false,
  );
}

/// Where hosting and pairings are kept between launches.
final class RemoteStore {
  const RemoteStore(this._secrets);

  static const hostKey = 'everyai.remote.host';
  static const pairedKey = 'everyai.remote.paired';

  final SecretStore _secrets;

  Future<HostRegistration?> host() async {
    final raw = await _secrets.read(hostKey);
    if (raw == null) return null;
    try {
      return HostRegistration.fromJson(jsonDecode(raw) as Map<String, Object?>);
    } on Object {
      return null;
    }
  }

  Future<void> saveHost(HostRegistration? host) =>
      host == null ? _secrets.delete(hostKey) : _secrets.write(hostKey, jsonEncode(host.toJson()));

  Future<List<PairedHost>> paired() async {
    final raw = await _secrets.read(pairedKey);
    if (raw == null) return const [];
    try {
      return [for (final p in jsonDecode(raw) as List<Object?>) PairedHost.fromJson(p! as Map<String, Object?>)];
    } on Object {
      return const [];
    }
  }

  Future<void> savePaired(List<PairedHost> hosts) =>
      _secrets.write(pairedKey, jsonEncode([for (final h in hosts) h.toJson()]));
}
