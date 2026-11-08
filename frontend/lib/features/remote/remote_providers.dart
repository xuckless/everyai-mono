import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/platform_kind.dart';
import '../../core/providers.dart';
import '../attachments/attachment.dart';
import '../auth/auth_providers.dart' show authProvider;
import '../auth/domain/auth_state.dart';
import '../../core/net/api_error.dart' show HttpStatusError;
import '../code/automations/webhook_providers.dart' show webhookRunnerProvider;
import '../code/code_providers.dart' show CodeSessionState, Outgoing;
import '../code/domain/agent_mode.dart';
import '../code/domain/code_session.dart';
import '../code/domain/permissions.dart' show ApprovalScope;
import '../code/domain/questions.dart';
import '../code/domain/transcript.dart';
import '../code/gateway_key.dart' show secretStoreProvider;
import '../code/harness/events.dart';
import 'data/host_bridge.dart';
import 'data/host_link.dart';
import 'data/relay_client.dart';
import 'data/relay_socket.dart';
import 'data/remote_api.dart';
import 'data/remote_store.dart';
import 'domain/remote_crypto.dart';
import 'domain/remote_protocol.dart';
import 'host_mirror.dart';

final remoteStoreProvider = Provider<RemoteStore>((ref) => RemoteStore(ref.watch(secretStoreProvider)));

final remoteApiProvider = Provider<RemoteApi>((ref) => RemoteApi(ref.watch(apiClientProvider), authenticated: true));

/// Opens relay sockets; tests override it with a fake relay.
final relayConnectorProvider = Provider<RelayConnector>((ref) => connectRelay);

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

/// Whether this desktop's host is on the signed-in account:
///
/// ```text
///  signedOut ──sign in (with a host)──► claiming ──200──► linked
///                                         │──409──► otherAccount   (made under another account)
///                                         └──error──► failed ──next sign-in or launch──► claiming
///  any ──sign out──► signedOut
/// ```
///
/// Hosting works in every state: an account only lists the host on its
/// other devices and counts its relay use against the account's (larger)
/// limit.
enum HostClaim { signedOut, claiming, linked, otherAccount, failed }

@immutable
final class RemoteHostingState {
  const RemoteHostingState({
    this.host,
    this.fingerprint = '',
    this.link = const HostLinkState(),
    this.loaded = false,
    this.claim = HostClaim.signedOut,
  });

  /// Null until this desktop is set up as a host.
  final HostRegistration? host;

  /// This host's key fingerprint, shown with the code and in the QR.
  final String fingerprint;
  final HostLinkState link;
  final bool loaded;
  final HostClaim claim;

  bool get enabled => host?.enabled ?? false;

  RemoteHostingState copyWith({
    HostRegistration? host,
    String? fingerprint,
    HostLinkState? link,
    bool? loaded,
    HostClaim? claim,
  }) => RemoteHostingState(
    host: host ?? this.host,
    fingerprint: fingerprint ?? this.fingerprint,
    link: link ?? this.link,
    loaded: loaded ?? this.loaded,
    claim: claim ?? this.claim,
  );
}

final remoteHostingProvider = NotifierProvider<RemoteHosting, RemoteHostingState>(RemoteHosting.new);

/// This desktop as a host for the account's other devices: registration,
/// the relay socket, pairing codes, approvals and the device list.
final class RemoteHosting extends Notifier<RemoteHostingState> {
  RemoteHostLink? _link;
  HostMirror? _mirror;
  StreamSubscription<HostLinkState>? _linkSub;

  @override
  RemoteHostingState build() {
    ref.onDispose(_stopLink);
    ref.listen(authProvider, (prev, next) {
      if (next is SignedIn && prev is! SignedIn) {
        unawaited(_claim());
      } else if (next is SignedOut) {
        _claiming = null;
        state = state.copyWith(claim: HostClaim.signedOut);
      }
    });
    if (Host.isDesktop) unawaited(_load());
    return const RemoteHostingState();
  }

  /// The claim under way; a second sign-in event joins it.
  Future<void>? _claiming;

  /// Puts this desktop's host on the signed-in account (idempotent on the
  /// backend), so its other devices list it. Nothing to do without a host.
  Future<void> _claim() => _claiming ??= _doClaim().whenComplete(() => _claiming = null);

  Future<void> _doClaim() async {
    final host = state.host ?? await _store.host();
    if (host == null || !ref.mounted || ref.read(authProvider) is! SignedIn) return;
    state = state.copyWith(claim: HostClaim.claiming);
    HostClaim next;
    try {
      await _api.claimHost(host.id, hostToken: host.token);
      next = HostClaim.linked;
    } on HttpStatusError catch (e) {
      next = e.statusCode == 409 ? HostClaim.otherAccount : HostClaim.failed;
    } on Object {
      next = HostClaim.failed;
    }
    // Signed out meanwhile: that wins.
    if (ref.mounted && ref.read(authProvider) is SignedIn) state = state.copyWith(claim: next);
  }

  RemoteStore get _store => ref.read(remoteStoreProvider);
  RemoteApi get _api => ref.read(remoteApiProvider);

  Future<void> _load() async {
    final host = await _store.host();
    if (!ref.mounted) return;
    if (host == null) {
      state = state.copyWith(loaded: true);
      return;
    }
    final identity = await RemoteIdentity.restore(host.privateKey);
    if (!ref.mounted) return;
    state = RemoteHostingState(host: host, fingerprint: keyFingerprint(identity.publicKey), loaded: true);
    unawaited(_claim());
    if (host.enabled) await _startLink(host, identity);
  }

  /// The [enable] under way: a second call (a double click, or Settings and Webhooks at once) joins it instead of
  /// registering a second host on the account.
  Future<void>? _enabling;

  /// Turns hosting on, registering this desktop with the backend the first time.
  Future<void> enable() => _enabling ??= _enable().whenComplete(() => _enabling = null);

  Future<void> _enable() async {
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
    unawaited(_claim());
    await _startLink(host, identity);
  }

  /// Turns hosting off: devices can't reach this desktop until it is on again.
  Future<void> disable() async {
    await _stopLink();
    final host = state.host?.copyWith(enabled: false);
    if (host != null) await _store.saveHost(host);
    state = RemoteHostingState(host: host, fingerprint: state.fingerprint, loaded: true);
  }

  /// Removes this host (from the account too, when claimed); every paired device loses it.
  Future<void> forget() async {
    final host = state.host;
    await _stopLink();
    if (host != null) {
      try {
        await _api.deleteHost(host.id, hostToken: host.token);
      } on Object {
        // Gone already, or offline: forget it here either way.
      }
    }
    await _store.saveHost(null);
    state = const RemoteHostingState(loaded: true);
  }

  Future<void> _startLink(HostRegistration host, RemoteIdentity identity) async {
    await _stopLink();
    // Devices mirror this computer's sessions; everything runs here.
    final mirror = _mirror = HostMirror(ref, hostName: host.name);
    final link = _link = RemoteHostLink(
      url: relayUrl(ref.read(appConfigProvider).apiBaseUrl, 'v1/remote/host'),
      token: host.token,
      connect: ref.read(relayConnectorProvider),
      approvedKey: (deviceId) => state.host?.devices[deviceId],
      // Webhooks for this host start sessions here; the ack goes back on whichever socket is up by then.
      onWebhook: (d) => unawaited(ref.read(webhookRunnerProvider.notifier).handle(d, (id) => _link?.ackWebhook(id))),
      bridge: (send) {
        final bridge = HostBridge(
          identity: identity,
          hostId: host.id,
          send: send,
          onMessage: mirror.receive,
          onChannelClosed: mirror.channelClosed,
        );
        mirror.send = bridge.send;
        return bridge;
      },
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
    _mirror?.dispose();
    _mirror = null;
  }

  /// A fresh single-use code (5 minutes) and the QR payload for it.
  Future<({PairingCode code, String qr})> newCode() async {
    final host = state.host;
    if (host == null) throw StateError('Turn hosting on first.');
    final code = await _api.newCode(host.id, hostToken: host.token);
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
    final host = state.host;
    if (host == null) return;
    await _api.deleteDevice(deviceId, hostToken: host.token);
    final updated = host.copyWith(devices: {...host.devices}..remove(deviceId));
    await _store.saveHost(updated);
    state = state.copyWith(host: updated);
  }
}

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
      unawaited(api.deleteDevice(r.deviceId, deviceToken: r.deviceToken).catchError((Object _) {}));
      throw const RemoteCryptoError('The host sent an invalid key.');
    }
    if ((expected != null && !sameFingerprint(expected, actual)) ||
        (payload.hostId != null && payload.hostId != r.hostId)) {
      unawaited(api.deleteDevice(r.deviceId, deviceToken: r.deviceToken).catchError((Object _) {}));
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
    final status = await ref.read(remoteApiProvider).pairingStatus(host.pairingId, deviceToken: host.deviceToken);
    switch (status) {
      case 'approved':
        await _save([for (final h in _hosts) h.hostId == host.hostId && h.deviceId == host.deviceId ? h.approve() : h]);
      case 'denied' || 'expired':
        await _save([..._hosts.where((h) => h.deviceId != host.deviceId)]);
    }
    return status;
  }

  /// Unpairs this device from [hostId].
  Future<void> unpair(String hostId) async {
    final host = _hosts.where((h) => h.hostId == hostId).firstOrNull;
    if (host == null) return;
    try {
      await ref.read(remoteApiProvider).deleteDevice(host.deviceId, deviceToken: host.deviceToken);
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

  Future<void> drop(String hostId) async {
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

// ------------------------------------------------------------------ mirrored sessions (device side)

/// The paired host this device follows. One for now: a second computer's
/// sessions would need their own list and routes.
final remoteHostProvider = Provider<PairedHost?>(
  (ref) => ref.watch(pairedHostsProvider).value?.where((h) => h.approved).firstOrNull,
);

/// One of the host's sessions in its list.
@immutable
final class RemoteSessionEntry {
  const RemoteSessionEntry(this.info, this.status);
  final CodeSessionInfo info;
  final SessionStatus status;
}

@immutable
final class RemoteSessionsState {
  const RemoteSessionsState({
    this.hostName = '',
    this.projects = const [],
    this.sessions = const [],
    this.link = RemoteLinkStatus.connecting,
    this.loaded = false,
    this.paired = false,
  });

  final String hostName;
  final List<CodeProject> projects;

  /// Newest first; subagents too (their parent's transcript opens them).
  final List<RemoteSessionEntry> sessions;
  final RemoteLinkStatus link;

  /// The host sent its list at least once.
  final bool loaded;

  /// This device is paired with a host at all.
  final bool paired;

  RemoteSessionEntry? byId(String id) => sessions.where((s) => s.info.id == id).firstOrNull;

  RemoteSessionsState copyWith({
    String? hostName,
    List<CodeProject>? projects,
    List<RemoteSessionEntry>? sessions,
    RemoteLinkStatus? link,
    bool? loaded,
  }) => RemoteSessionsState(
    hostName: hostName ?? this.hostName,
    projects: projects ?? this.projects,
    sessions: sessions ?? this.sessions,
    link: link ?? this.link,
    loaded: loaded ?? this.loaded,
    paired: paired,
  );
}

/// The host's Code sessions, kept current by the host while this device follows them.
final remoteSessionsProvider = NotifierProvider<RemoteSessions, RemoteSessionsState>(RemoteSessions.new);

final class RemoteSessions extends Notifier<RemoteSessionsState> {
  final _subs = <StreamSubscription<Object?>>[];

  @override
  RemoteSessionsState build() {
    final host = ref.watch(remoteHostProvider);
    ref.onDispose(() {
      for (final s in _subs) {
        unawaited(s.cancel());
      }
      _subs.clear();
    });
    if (host == null) return const RemoteSessionsState(loaded: true);
    unawaited(_follow(host));
    return RemoteSessionsState(hostName: host.name, paired: true);
  }

  Future<void> _follow(PairedHost host) async {
    final RemoteClient client;
    try {
      client = await ref.read(remoteLinksProvider).client(host.hostId);
    } on Object {
      return;
    }
    if (!ref.mounted) return;
    void ask() => unawaited(client.send({'t': Tunnel.list}).catchError((Object _) {}));
    _subs
      ..add(
        client.statusChanges.listen((s) {
          state = state.copyWith(link: s);
          // The host forgets what a device followed when the link drops.
          if (s == RemoteLinkStatus.ready) ask();
        }),
      )
      ..add(client.messages.where((m) => m['t'] == Tunnel.sessions).listen(_list));
    state = state.copyWith(link: client.status);
    ask();
  }

  void _list(Map<String, Object?> m) {
    final sessions = <RemoteSessionEntry>[];
    for (final raw in m['sessions'] as List<Object?>? ?? const []) {
      if (raw is! Map<String, Object?>) continue;
      try {
        sessions.add(
          RemoteSessionEntry(
            CodeSessionInfo.fromJson(raw),
            SessionStatus.values.asNameMap()[raw['status']] ?? SessionStatus.idle,
          ),
        );
      } on Object {
        // A session this build can't read; the rest still show.
      }
    }
    sessions.sort((a, b) => b.info.createdAt.compareTo(a.info.createdAt));
    state = state.copyWith(
      hostName: m['host'] as String? ?? state.hostName,
      projects: [
        for (final p in m['projects'] as List<Object?>? ?? const [])
          if (p case {'id': final String id, 'name': final String name}) CodeProject(id: id, name: name, path: ''),
      ],
      sessions: sessions,
      loaded: true,
    );
  }
}

/// A mirrored session: what the host's controller shows, folded here from
/// the same events, plus what the approval card needs.
@immutable
final class RemoteSessionState {
  const RemoteSessionState({
    this.session = const CodeSessionState(),
    this.remember,
    this.flags = const {},
    this.reasons = const {},
    this.rememberBy = const {},
    this.perCall = false,
    this.forks = false,
    this.link = RemoteLinkStatus.connecting,
    this.loaded = false,
    this.gone,
  });

  /// Transcript, mode, queue and status, as on the host.
  final CodeSessionState session;

  /// What "allow for this session / always" would remember, or null when it can't.
  final List<String>? remember;

  /// Pending calls the host's rules call dangerous, with why.
  final Map<String, String> flags;

  /// Why each pending call asks (the rule or the mode), from the host.
  final Map<String, String> reasons;

  /// Per pending call, the rule "for this session / always" would store.
  final Map<String, String> rememberBy;

  /// The host's session takes one answer per call.
  final bool perCall;

  /// A fork's or subagent's: "for this session" covers all the session's forks.
  final bool forks;
  final RemoteLinkStatus link;

  /// The host sent the session at least once.
  final bool loaded;

  /// Why the host can't show it (deleted there), or null.
  final String? gone;

  RemoteSessionState copyWith({
    CodeSessionState? session,
    List<String>? remember,
    bool clearRemember = false,
    Map<String, String>? flags,
    Map<String, String>? reasons,
    Map<String, String>? rememberBy,
    bool? perCall,
    bool? forks,
    RemoteLinkStatus? link,
    bool? loaded,
    String? gone,
  }) => RemoteSessionState(
    session: session ?? this.session,
    remember: clearRemember ? null : remember ?? this.remember,
    flags: flags ?? this.flags,
    reasons: reasons ?? this.reasons,
    rememberBy: rememberBy ?? this.rememberBy,
    perCall: perCall ?? this.perCall,
    forks: forks ?? this.forks,
    link: link ?? this.link,
    loaded: loaded ?? this.loaded,
    gone: gone ?? this.gone,
  );
}

final remoteSessionProvider = NotifierProvider.autoDispose.family<RemoteSession, RemoteSessionState, String>(
  RemoteSession.new,
);

/// Follows one of the host's sessions and sends the user's actions to it.
/// The host runs them on its own controller; nothing is decided here.
final class RemoteSession extends Notifier<RemoteSessionState> {
  RemoteSession(this.sessionId);
  final String sessionId;

  RemoteClient? _client;
  final _fold = MirrorFold();
  final _subs = <StreamSubscription<Object?>>[];

  @override
  RemoteSessionState build() {
    final host = ref.read(remoteHostProvider);
    ref.onDispose(() {
      for (final s in _subs) {
        unawaited(s.cancel());
      }
      final client = _client;
      if (client != null && client.status == RemoteLinkStatus.ready) {
        unawaited(client.send({'t': Tunnel.close, 's': sessionId}).catchError((Object _) {}));
      }
    });
    if (host == null) return const RemoteSessionState(gone: 'This device is not paired with a computer.');
    unawaited(_follow(host));
    return const RemoteSessionState();
  }

  Future<void> _follow(PairedHost host) async {
    final RemoteClient client;
    try {
      client = _client = await ref.read(remoteLinksProvider).client(host.hostId);
    } on Object catch (e) {
      if (ref.mounted) state = state.copyWith(gone: '$e');
      return;
    }
    if (!ref.mounted) return;
    void open() => unawaited(client.send({'t': Tunnel.open, 's': sessionId}).catchError((Object _) {}));
    _subs
      ..add(
        client.statusChanges.listen((s) {
          state = state.copyWith(link: s);
          if (s == RemoteLinkStatus.ready) open();
        }),
      )
      ..add(client.messages.where((m) => m['s'] == sessionId).listen(_receive));
    state = state.copyWith(link: client.status);
    open();
  }

  void _receive(Map<String, Object?> m) => state = _fold.apply(state, m);

  Future<void> _act(String kind, [Map<String, Object?> args = const {}]) async {
    final client = _client;
    if (client == null) throw const RemoteUnavailable('Not connected to the computer yet.');
    await client.call({'t': Tunnel.act, 's': sessionId, 'kind': kind, 'args': args});
  }

  static List<Map<String, Object?>> _files(List<Attachment> files) => [
    for (final f in files) {'name': f.name, 'mime': f.mime, 'data': base64Encode(f.bytes)},
  ];

  Future<void> send(String text, {List<Attachment> files = const []}) =>
      _act(MirrorAction.send, {'text': text, if (files.isNotEmpty) 'files': _files(files)});

  Future<void> steer(String text, {List<Attachment> files = const []}) =>
      _act(MirrorAction.steer, {'text': text, if (files.isNotEmpty) 'files': _files(files)});

  Future<void> stop() => _act(MirrorAction.stop);

  Future<void> approve([ApprovalScope scope = ApprovalScope.once, List<String>? callIds]) =>
      _act(MirrorAction.approve, {'scope': scope.name, 'call_ids': ?callIds});

  Future<void> deny([String? reason, List<String>? callIds]) =>
      _act(MirrorAction.deny, {'reason': ?reason, 'call_ids': ?callIds});

  Future<void> answer(QuestionItem item, List<QuestionAnswer> answers) => _act(MirrorAction.answer, {
    'call': item.call.id,
    'answers': [
      for (final a in answers) {'selected': (a.selected.toList()..sort()), 'other': a.other},
    ],
  });

  Future<void> setMode(AgentMode mode) => _act(MirrorAction.mode, {'mode': mode.name});

  Future<void> startBuilding() => _act(MirrorAction.build);

  Future<void> retry() => _act(MirrorAction.retry);

  Future<void> retryNow() => _act(MirrorAction.retryNow);

  Future<void> unqueue(int index) => _act(MirrorAction.unqueue, {'index': index});
}

/// Folds what the host sends about one session (`reset`, `events`, `state`,
/// `gone`) into what this device shows: the same transcript builder the host
/// runs, fed the same events.
final class MirrorFold {
  var _builder = TranscriptBuilder();

  RemoteSessionState apply(RemoteSessionState state, Map<String, Object?> m) {
    switch (m['t']) {
      case Tunnel.reset:
        _builder = TranscriptBuilder();
        return state.copyWith(session: state.session.copyWith(transcript: _builder.snapshot));
      case Tunnel.events:
        for (final raw in m['events'] as List<Object?>? ?? const []) {
          if (raw is Map<String, Object?>) _builder.add(HarnessEvent.decode(raw));
        }
        return state.copyWith(session: state.session.copyWith(transcript: _builder.snapshot), loaded: true);
      case Tunnel.state:
        final s = state.session;
        return state.copyWith(
          session: CodeSessionState(
            transcript: s.transcript,
            mode: AgentMode.values.asNameMap()[m['mode']] ?? s.mode,
            queued: [
              for (final q in m['queued'] as List<Object?>? ?? const [])
                if (q is String) Outgoing(q),
            ],
            connected: m['connected'] == true,
            error: m['error'] as String?,
            subagentNeedsInput: m['subagent_needs_input'] == true,
            decided: {
              for (final e in (m['decided'] as Map<String, Object?>? ?? const {}).entries)
                if (e.value case final bool ok) e.key: ok,
            },
          ),
          rememberBy: {
            for (final e in (m['remember_by'] as Map<String, Object?>? ?? const {}).entries)
              if (e.value case final String rule) e.key: rule,
          },
          perCall: m['per_call'] == true,
          forks: m['forks'] == true,
          remember: [
            for (final p in m['remember'] as List<Object?>? ?? const [])
              if (p is String) p,
          ],
          clearRemember: m['remember'] == null,
          flags: {
            for (final e in (m['flags'] as Map<String, Object?>? ?? const {}).entries)
              if (e.value case final String why) e.key: why,
          },
          reasons: {
            for (final e in (m['reasons'] as Map<String, Object?>? ?? const {}).entries)
              if (e.value case final String why) e.key: why,
          },
          loaded: true,
        );
      case Tunnel.gone:
        return state.copyWith(gone: m['message'] as String? ?? 'This session is gone.');
      default:
        return state;
    }
  }
}
