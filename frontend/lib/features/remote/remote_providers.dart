import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/platform_kind.dart';
import '../../core/providers.dart';
import '../code/code_providers.dart'
    show
        codeHarnessProvider,
        codeProjectsProvider,
        codeSessionsProvider,
        everyaiAgentServerProvider,
        isDemoPath,
        sidecarProvider;
import '../code/domain/agent_menu.dart' show CodeHarnessKind;
import '../auth/data/token_store.dart' show tokenStoreProvider;
import '../code/gateway_key.dart' show secretStoreProvider;
import 'data/host_bridge.dart';
import 'data/host_link.dart';
import 'data/relay_client.dart';
import 'data/relay_socket.dart';
import 'data/remote_api.dart';
import 'data/remote_store.dart';
import 'domain/remote_crypto.dart';
import 'domain/remote_protocol.dart';
import 'relay_harness.dart';

final remoteStoreProvider = Provider<RemoteStore>((ref) => RemoteStore(ref.watch(secretStoreProvider)));

final remoteApiProvider = Provider<RemoteApi>(
  (ref) => RemoteApi(ref.watch(apiClientProvider), authenticated: !ref.watch(appConfigProvider).devSkipAuth),
);

/// Opens relay sockets; tests override it with a fake relay.
final relayConnectorProvider = Provider<RelayConnector>((ref) {
  final tokens = ref.watch(tokenStoreProvider);
  return (url, token) async => connectRelay(url, token, userToken: await tokens.accessToken());
});

/// A name for this device, as other devices and the host list show it.
String thisDeviceName() {
  if (kIsWeb) return 'Web browser';
  return switch (defaultTargetPlatform) {
    TargetPlatform.macOS => 'Mac',
    TargetPlatform.windows => 'Windows PC',
    TargetPlatform.linux => 'Linux PC',
    TargetPlatform.iOS => 'iPhone or iPad',
    TargetPlatform.android => 'Android device',
    TargetPlatform.fuchsia => 'Device',
  };
}

String _platform() => kIsWeb ? 'web' : defaultTargetPlatform.name;

// ------------------------------------------------------------------ host mode (desktop)

@immutable
final class RemoteHostingState {
  const RemoteHostingState({this.host, this.fingerprint = '', this.link = const HostLinkState(), this.loaded = false});

  /// Null until this desktop is set up as a host.
  final HostRegistration? host;

  /// This host's key fingerprint, shown with the code and in the QR.
  final String fingerprint;
  final HostLinkState link;
  final bool loaded;

  bool get enabled => host?.enabled ?? false;

  RemoteHostingState copyWith({HostRegistration? host, String? fingerprint, HostLinkState? link, bool? loaded}) =>
      RemoteHostingState(
        host: host ?? this.host,
        fingerprint: fingerprint ?? this.fingerprint,
        link: link ?? this.link,
        loaded: loaded ?? this.loaded,
      );
}

final remoteHostingProvider = NotifierProvider<RemoteHosting, RemoteHostingState>(RemoteHosting.new);

/// This desktop as a host for the account's other devices: registration,
/// the relay socket, pairing codes, approvals and the device list.
final class RemoteHosting extends Notifier<RemoteHostingState> {
  RemoteHostLink? _link;
  StreamSubscription<HostLinkState>? _linkSub;

  @override
  RemoteHostingState build() {
    ref.onDispose(_stopLink);
    if (Host.isDesktop) unawaited(_load());
    return const RemoteHostingState();
  }

  RemoteStore get _store => ref.read(remoteStoreProvider);
  RemoteApi get _api => ref.read(remoteApiProvider);

  /// Bumped on sign-out, so a load still under way doesn't start hosting again.
  int _epoch = 0;

  Future<void> _load() async {
    final epoch = _epoch;
    final host = await _store.host();
    if (epoch != _epoch || !ref.mounted) return;
    if (host == null) {
      state = state.copyWith(loaded: true);
      return;
    }
    final identity = await RemoteIdentity.restore(host.privateKey);
    if (epoch != _epoch || !ref.mounted) return;
    state = RemoteHostingState(host: host, fingerprint: keyFingerprint(identity.publicKey), loaded: true);
    if (host.enabled) await _startLink(host, identity);
  }

  /// The account signed out: hosting stops and this desktop leaves the
  /// account. Its `rh_` token and key belong to that account, so the next
  /// one to sign in sets up hosting of its own, and the old account's
  /// devices can no longer reach this computer. Call it while still signed
  /// in (the host is removed on the backend too, best effort).
  Future<void> signedOut() async {
    _epoch++;
    final host = state.host ?? await _store.host();
    await _stopLink();
    if (host != null) {
      try {
        await _api.deleteHost(host.id);
      } on Object {
        // Offline: the backend's entry stays, but nothing here can use it.
      }
    }
    await _store.saveHost(null);
    if (ref.mounted) state = const RemoteHostingState(loaded: true);
  }

  /// Turns hosting on, registering this desktop with the backend the first time.
  Future<void> enable() async {
    var host = state.host;
    RemoteIdentity identity;
    if (host == null) {
      identity = await RemoteIdentity.generate();
      final name = thisDeviceName();
      final r = await _api.registerHost(name: name, platform: _platform(), publicKey: identity.publicKeyBase64);
      host = HostRegistration(id: r.id, name: name, token: r.token, privateKey: identity.privateKeyBase64);
    } else {
      identity = await RemoteIdentity.restore(host.privateKey);
      host = host.copyWith(enabled: true);
    }
    await _store.saveHost(host);
    state = state.copyWith(host: host, fingerprint: keyFingerprint(identity.publicKey));
    await _startLink(host, identity);
  }

  /// Turns hosting off: devices can't reach this desktop until it is on again.
  Future<void> disable() async {
    await _stopLink();
    final host = state.host?.copyWith(enabled: false);
    if (host != null) await _store.saveHost(host);
    state = RemoteHostingState(host: host, fingerprint: state.fingerprint, loaded: true);
  }

  /// Removes this host from the account; every paired device loses it.
  Future<void> forget() async {
    final host = state.host;
    await _stopLink();
    if (host != null) {
      try {
        await _api.deleteHost(host.id);
      } on Object {
        // Gone already, or offline: forget it here either way.
      }
    }
    await _store.saveHost(null);
    state = const RemoteHostingState(loaded: true);
  }

  Future<void> _startLink(HostRegistration host, RemoteIdentity identity) async {
    await _stopLink();
    final link = _link = RemoteHostLink(
      url: relayUrl(ref.read(appConfigProvider).apiBaseUrl, 'v1/remote/host'),
      token: host.token,
      connect: ref.read(relayConnectorProvider),
      approvedKey: (deviceId) => state.host?.devices[deviceId],
      bridge: (send) => HostBridge(
        identity: identity,
        hostId: host.id,
        send: send,
        // Devices get the harness this host starts sessions on.
        locate: () async {
          if (ref.read(codeHarnessProvider) == CodeHarnessKind.everyai) {
            final served = await ref.read(everyaiAgentServerProvider.future);
            return (served.baseUrl, served.key);
          }
          final e = await ref.read(sidecarProvider).endpoint();
          return (e.baseUrl, e.sessionApiKey);
        },
        projects: _projects,
        allowedDir: _allowedDir,
      ),
    );
    _linkSub = link.changes.listen((s) {
      state = state.copyWith(link: s);
      if (s.revoked) unawaited(forget());
    });
    link.start();
  }

  Future<void> _stopLink() async {
    await _linkSub?.cancel();
    _linkSub = null;
    final link = _link;
    _link = null;
    await link?.close();
  }

  List<HostProject> _projects() => [
    for (final p in ref.read(codeProjectsProvider))
      if (!isDemoPath(p.path) && !isRemotePath(p.path)) (name: p.name, path: p.path),
  ];

  /// A device may start sessions in the host's projects and in the worktrees
  /// of its sessions (paths compared normalized, so `..` can't climb out).
  bool _allowedDir(String dir) => hostOffers(dir, [
    for (final p in _projects()) p.path,
    for (final s in ref.read(codeSessionsProvider))
      if (s.workingDir.isNotEmpty && !isDemoPath(s.workingDir) && !isRemotePath(s.workingDir)) s.workingDir,
  ]);

  /// A fresh single-use code (5 minutes) and the QR payload for it.
  Future<({PairingCode code, String qr})> newCode() async {
    final host = state.host;
    if (host == null) throw StateError('Turn hosting on first.');
    final code = await _api.newCode(host.id);
    final qr = PairingPayload(
      code: code.code,
      hostId: host.id,
      fingerprint: state.fingerprint,
      hostName: host.name,
    ).toUri();
    return (code: code, qr: qr);
  }

  /// Approves or denies a device. An approved device's key is remembered, so
  /// only that key can connect as it.
  Future<void> decide(PairRequest request, {required bool approve}) async {
    final host = state.host;
    if (host == null) return;
    await _api.decide(request.pairingId, approve: approve, hostToken: host.token);
    if (approve) {
      final updated = host.copyWith(devices: {...host.devices, request.deviceId: request.publicKey});
      await _store.saveHost(updated);
      state = state.copyWith(host: updated);
    }
    _link?.settled(request.pairingId);
  }

  /// The devices paired with this host.
  Future<List<RemoteDevice>> devices() async {
    final host = state.host;
    if (host == null) return const [];
    final hosts = await _api.hosts();
    return hosts.where((h) => h.id == host.id).firstOrNull?.devices ?? const [];
  }

  Future<void> revokeDevice(String deviceId) async {
    await _api.deleteDevice(deviceId);
    final host = state.host;
    if (host == null) return;
    final updated = host.copyWith(devices: {...host.devices}..remove(deviceId));
    await _store.saveHost(updated);
    state = state.copyWith(host: updated);
  }
}

/// Whether [dir] is in one of [roots], all normalized first.
bool hostOffers(String dir, Iterable<String> roots) => roots.any((root) => pathWithin(dir, root));

// ------------------------------------------------------------------ device side

final pairedHostsProvider = AsyncNotifierProvider<PairedHosts, List<PairedHost>>(PairedHosts.new);

/// Whether this device has an approved host, so Code shows in remote mode.
final hasRemoteHostProvider = Provider<bool>(
  (ref) => ref.watch(pairedHostsProvider).value?.any((h) => h.approved) ?? false,
);

/// The hosts this device paired with.
final class PairedHosts extends AsyncNotifier<List<PairedHost>> {
  @override
  Future<List<PairedHost>> build() => ref.read(remoteStoreProvider).paired();

  Future<void> _save(List<PairedHost> hosts) async {
    await ref.read(remoteStoreProvider).savePaired(hosts);
    state = AsyncData(hosts);
  }

  List<PairedHost> get _hosts => state.value ?? const [];

  /// Claims [payload]'s code with a fresh key for this device. Fails when the
  /// QR's fingerprint doesn't match the key the backend returned.
  Future<PairedHost> redeem(PairingPayload payload) async {
    await future;
    final identity = await RemoteIdentity.generate();
    final api = ref.read(remoteApiProvider);
    final r = await api.redeem(code: payload.code, deviceName: thisDeviceName(), publicKey: identity.publicKeyBase64);
    final expected = payload.fingerprint;
    final String actual;
    try {
      actual = keyFingerprint(decodePublicKey(r.hostPublicKey));
    } on RemoteCryptoError {
      unawaited(api.deleteDevice(r.deviceId).catchError((Object _) {}));
      throw const RemoteCryptoError('The host sent an invalid key.');
    }
    if ((expected != null && !sameFingerprint(expected, actual)) ||
        (payload.hostId != null && payload.hostId != r.hostId)) {
      unawaited(api.deleteDevice(r.deviceId).catchError((Object _) {}));
      throw const RemoteCryptoError("The host's key doesn't match the QR code. Pairing stopped.");
    }
    final host = PairedHost(
      hostId: r.hostId,
      name: r.hostName,
      platform: r.hostPlatform,
      hostPublicKey: r.hostPublicKey,
      deviceId: r.deviceId,
      deviceToken: r.deviceToken,
      privateKey: identity.privateKeyBase64,
      pairingId: r.pairingId,
    );
    // Pairing again with the same host replaces the old device.
    await _save([..._hosts.where((h) => h.hostId != host.hostId), host]);
    return host;
  }

  /// Asks whether the host decided on [host]; returns the status
  /// (`pending`, `approved`, `denied` or `expired`). A denied or expired
  /// pairing is dropped.
  Future<String> poll(PairedHost host) async {
    final status = await ref.read(remoteApiProvider).pairingStatus(host.pairingId);
    switch (status) {
      case 'approved':
        await _save([for (final h in _hosts) h.hostId == host.hostId && h.deviceId == host.deviceId ? h.approve() : h]);
      case 'denied' || 'expired':
        await _save([..._hosts.where((h) => h.deviceId != host.deviceId)]);
    }
    return status;
  }

  /// The account signed out: every pairing goes, here and on the backend
  /// (best effort), and the open links close. The `rd_` tokens and keys
  /// belong to that account; the next one to sign in pairs its own.
  Future<void> signedOut() async {
    final store = ref.read(remoteStoreProvider);
    final hosts = state.value ?? await store.paired();
    await ref.read(remoteLinksProvider).closeAll();
    for (final h in hosts) {
      try {
        await ref.read(remoteApiProvider).deleteDevice(h.deviceId);
      } on Object {
        // Offline or gone already.
      }
    }
    await store.savePaired(const []);
    if (ref.mounted) state = const AsyncData([]);
  }

  /// Unpairs this device from [hostId].
  Future<void> unpair(String hostId) async {
    final host = _hosts.where((h) => h.hostId == hostId).firstOrNull;
    if (host == null) return;
    try {
      await ref.read(remoteApiProvider).deleteDevice(host.deviceId);
    } on Object {
      // Already gone on the backend.
    }
    await ref.read(remoteLinksProvider).drop(hostId);
    await _save([..._hosts.where((h) => h.hostId != hostId)]);
  }
}

final remoteLinksProvider = Provider<RemoteLinks>((ref) {
  final links = RemoteLinks(ref);
  ref.onDispose(links.closeAll);
  return links;
});

/// One encrypted link per paired host, opened on first use.
final class RemoteLinks {
  RemoteLinks(this._ref);

  final Ref _ref;
  final _clients = <String, Future<RemoteClient>>{};
  final _harnesses = <String, RelayHarness>{};

  Future<RemoteClient> client(String hostId) => _clients[hostId] ??= _open(hostId);

  Future<RemoteClient> _open(String hostId) async {
    final hosts = await _ref.read(pairedHostsProvider.future);
    final host = hosts.where((h) => h.hostId == hostId && h.approved).firstOrNull;
    if (host == null) {
      _clients.remove(hostId)?.ignore();
      throw const RemoteUnavailable('This device is not paired with that host.');
    }
    final client = RemoteClient(
      hostId: host.hostId,
      hostPublicKey: decodePublicKey(host.hostPublicKey),
      identity: await RemoteIdentity.restore(host.privateKey),
      deviceToken: host.deviceToken,
      relayUrl: relayUrl(_ref.read(appConfigProvider).apiBaseUrl, 'v1/remote/client/${host.hostId}'),
      connect: _ref.read(relayConnectorProvider),
    )..start();
    return client;
  }

  Future<RelayHarness> harness(String hostId) async {
    if (_harnesses[hostId] case final h?) return h;
    return _harnesses[hostId] = RelayHarness(await client(hostId));
  }

  Future<void> drop(String hostId) async {
    _harnesses.remove(hostId);
    final client = _clients.remove(hostId);
    if (client != null) await (await client).close();
  }

  Future<void> closeAll() async {
    for (final id in [..._clients.keys]) {
      await drop(id).catchError((Object _) {});
    }
  }
}

/// A paired host's link status, for the host list.
final remoteLinkStatusProvider = StreamProvider.family<RemoteLinkStatus, String>((ref, hostId) async* {
  final client = await ref.read(remoteLinksProvider).client(hostId);
  yield client.status;
  yield* client.statusChanges;
});
