import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/api_client.dart';
import '../../core/net/api_error.dart';
import '../../core/providers.dart';
import '../code/gateway_key.dart';
import '../remote/remote_providers.dart' show thisDeviceName;
import 'data/magic_api.dart';
import 'data/token_store.dart';
import 'domain/auth_state.dart';

final authProvider = NotifierProvider<AuthController, AuthState>(AuthController.new);

/// The magic-link endpoints; tests answer without a server.
final magicApiProvider = Provider<MagicApi>((ref) => HttpMagicApi(ref.watch(apiClientProvider)));

/// How often a waiting sign-in asks whether the link was pressed.
final magicPollIntervalProvider = Provider<Duration>((_) => const Duration(seconds: 2));

/// The name the sign-in email and page show ("Sign in EveryAI on Mac?").
final signInDeviceNameProvider = Provider<String>((_) => thisDeviceName());

/// `base` so tests can stand in a fake (`authProvider.overrideWith`).
base class AuthController extends Notifier<AuthState> {
  TokenStore get _tokens => ref.read(tokenStoreProvider);
  ApiClient get _api => ref.read(apiClientProvider);
  MagicApi get _magic => ref.read(magicApiProvider);

  /// Bumped by every new flow and by cancel: late answers of an older one
  /// are dropped.
  int _gen = 0;
  Timer? _poller;
  bool _polling = false;

  @override
  AuthState build() {
    ref.onDispose(_stopPolling);
    unawaited(_restore());
    return const Restoring();
  }

  Future<void> _restore() async {
    String? token;
    try {
      token = await _tokens.refreshAccessToken();
    } on Object {
      // No keychain (a test, a locked keyring) or no server: signed out,
      // which the app handles like any other state.
      token = null;
    }
    if (!ref.mounted || state is! Restoring) return;
    state = token == null ? const SignedOut() : const SignedIn();
  }

  MagicFlow? get _flow => switch (state) {
    SigningIn(:final flow) => flow,
    _ => null,
  };

  void _setFlow(MagicFlow flow) {
    if (!ref.mounted) return;
    state = SigningIn(flow);
    final waiting = flow is Waiting || flow is Verifying;
    if (waiting) {
      _startPolling();
    } else {
      _stopPolling();
    }
  }

  /// Opens the email step (Settings → Account, the account menu).
  void startSignIn({String email = ''}) {
    if (state is SignedIn || state is SigningOut) return;
    _setFlow(EnterEmail(++_gen, email: email));
  }

  /// Back to signed out; any answer still on its way is ignored.
  void cancelSignIn() {
    if (state is! SigningIn) return;
    _gen++;
    _stopPolling();
    state = const SignedOut();
  }

  /// Sends the email with the link and code.
  Future<void> ask(String email) async {
    final address = email.trim();
    if (_flow case Requesting()) return;
    final gen = ++_gen;
    _setFlow(Requesting(gen, address));
    try {
      final asked = await _magic.ask(address, deviceName: ref.read(signInDeviceNameProvider));
      if (gen != _gen) return;
      _setFlow(
        Waiting(
          gen,
          email: address,
          requestId: asked.requestId,
          secret: asked.secret,
          sentAt: DateTime.now(),
          expiresAt: asked.expiresAt,
        ),
      );
    } on ApiError catch (e) {
      if (gen == _gen) _setFlow(EnterEmail(gen, email: address, error: e.message));
    }
  }

  /// Checks a typed code; one at a time.
  Future<void> enterCode(String code) async {
    final Waiting waiting;
    switch (_flow) {
      case final Waiting w:
        waiting = w;
      default:
        return;
    }
    final gen = waiting.gen;
    _setFlow(Verifying(waiting.withError(null)));
    try {
      final answer = await _magic.code(waiting.requestId, waiting.secret, code.trim());
      if (gen != _gen) return;
      await _settle(gen, answer, waiting);
    } on WrongCode catch (e) {
      if (gen != _gen || _flow is! Verifying) return;
      _setFlow(
        e.dead
            ? Expired(gen, email: waiting.email, reason: 'Too many wrong codes. Ask for a new email.')
            : waiting.withError("That code isn't right."),
      );
    } on ApiError catch (e) {
      if (gen == _gen && _flow is Verifying) _setFlow(waiting.withError(e.message));
    }
  }

  /// The link was pressed or the deep link came back: ask now instead of
  /// at the next tick.
  Future<void> pollNow() => _pollOnce();

  void _startPolling() {
    _poller ??= Timer.periodic(ref.read(magicPollIntervalProvider), (_) => unawaited(_pollOnce()));
  }

  void _stopPolling() {
    _poller?.cancel();
    _poller = null;
  }

  Future<void> _pollOnce() async {
    final waiting = switch (_flow) {
      final Waiting w => w,
      Verifying(:final waiting) => waiting,
      _ => null,
    };
    if (waiting == null || _polling) return;
    _polling = true;
    try {
      final answer = await _magic.poll(waiting.requestId, waiting.secret);
      if (waiting.gen != _gen) return;
      await _settle(waiting.gen, answer, waiting);
    } on ApiError {
      // Offline for a moment: the next tick asks again.
    } finally {
      _polling = false;
    }
  }

  /// Applies a poll or code answer: signed in with tokens, or the request
  /// ended, or still waiting.
  Future<void> _settle(int gen, MagicAnswer answer, Waiting waiting) async {
    if (answer case (accessToken: final String access, refreshToken: final String refresh, status: _)) {
      _stopPolling();
      _gen++;
      await _tokens.save(accessToken: access, refreshToken: refresh);
      if (ref.mounted) state = const SignedIn();
      return;
    }
    final reason = switch (answer.status) {
      'expired' => 'This email has expired. Ask for a new one.',
      'denied' => 'Sign-in was refused from the email ("Not me").',
      'dead' => 'Too many wrong codes. Ask for a new email.',
      // Redeemed by another poll of ours that already won: nothing to do.
      _ => null,
    };
    if (reason != null) {
      _setFlow(Expired(gen, email: waiting.email, reason: reason));
    } else if (_flow is Verifying) {
      _setFlow(waiting);
    }
  }

  Future<void>? _signingOut;

  /// Ends the account session on this device. Remote pairings stay: they
  /// work without an account (owner, 2026-11-08), and unpairing is its own
  /// action in Settings → Remote.
  Future<void> signOut() => _signingOut ??= _signOut().whenComplete(() => _signingOut = null);

  Future<void> _signOut() async {
    if (state is! SignedIn) return;
    state = const SigningOut();
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
    if (ref.mounted) state = const SignedOut();
  }

  /// Every device of this account signs out (refresh tokens revoked on the
  /// server), this one included.
  Future<void> signOutEverywhere() async {
    if (state is! SignedIn) return;
    await _api.postJson('v1/auth/logout_all', const {}, authenticated: true);
    await signOut();
  }
}
