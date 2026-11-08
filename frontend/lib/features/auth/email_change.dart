import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/api_error.dart';
import '../../core/providers.dart';
import 'auth_providers.dart';
import 'data/magic_api.dart';
import 'domain/auth_state.dart';
import 'data/token_store.dart';
import 'profile.dart';

/// Moving the account to another address: a magic link to the new one.
///
/// ```text
///  Idle ──send──► Sending ──202──► AwaitingLink ──link pressed / code──► Idle (moved)
///   ▲               │                  │
///   └──error────────┘                  └──expired/denied/cancel──► Idle (with note)
/// ```
sealed class EmailChange {
  const EmailChange();
}

final class EmailIdle extends EmailChange {
  const EmailIdle({this.note});

  /// What happened last ("Moved to …", "That address already has an account.").
  final String? note;
}

final class EmailSending extends EmailChange {
  const EmailSending(this.email);
  final String email;
}

final class EmailAwaitingLink extends EmailChange {
  const EmailAwaitingLink({required this.email, required this.requestId, required this.secret, this.codeError});
  final String email;
  final String requestId;
  final String secret;
  final String? codeError;
}

final emailChangeProvider = NotifierProvider.autoDispose<EmailChangeController, EmailChange>(EmailChangeController.new);

final class EmailChangeController extends Notifier<EmailChange> {
  int _gen = 0;
  Timer? _poller;
  bool _polling = false;

  @override
  EmailChange build() {
    ref.onDispose(() => _poller?.cancel());
    return const EmailIdle();
  }

  Future<void> send(String email) async {
    if (state is EmailSending) return;
    final gen = ++_gen;
    final address = email.trim();
    state = EmailSending(address);
    try {
      final json = await ref.read(apiClientProvider).postJson('v1/auth/email', {
        'email': address,
        'device_name': ref.read(signInDeviceNameProvider),
      }, authenticated: true);
      if (gen != _gen) return;
      if (json case {'request_id': final String id, 'request_secret': final String secret}) {
        state = EmailAwaitingLink(email: address, requestId: id, secret: secret);
        _poller ??= Timer.periodic(ref.read(magicPollIntervalProvider), (_) => unawaited(_poll()));
      } else {
        state = const EmailIdle(note: 'Unexpected answer from the server.');
      }
    } on ApiError catch (e) {
      if (gen == _gen) state = EmailIdle(note: e.message);
    }
  }

  Future<void> enterCode(String code) async {
    final waiting = state;
    if (waiting is! EmailAwaitingLink) return;
    try {
      final answer = await ref.read(magicApiProvider).code(waiting.requestId, waiting.secret, code.trim());
      await _settle(answer, waiting);
    } on WrongCode catch (e) {
      if (state != waiting) return;
      state = e.dead
          ? const EmailIdle(note: 'Too many wrong codes. Try again.')
          : EmailAwaitingLink(
              email: waiting.email,
              requestId: waiting.requestId,
              secret: waiting.secret,
              codeError: "That code isn't right.",
            );
    } on ApiError catch (e) {
      if (state == waiting) state = EmailIdle(note: e.message);
    }
  }

  void cancel() {
    _gen++;
    _stop();
    state = const EmailIdle();
  }

  void _stop() {
    _poller?.cancel();
    _poller = null;
  }

  Future<void> _poll() async {
    final waiting = state;
    if (waiting is! EmailAwaitingLink || _polling) return;
    _polling = true;
    try {
      await _settle(await ref.read(magicApiProvider).poll(waiting.requestId, waiting.secret), waiting);
    } on ApiError {
      // The next tick asks again.
    } finally {
      _polling = false;
    }
  }

  Future<void> _settle(MagicAnswer answer, EmailAwaitingLink waiting) async {
    if (!ref.mounted || state != waiting) return;
    if (answer case (accessToken: final String access, refreshToken: final String refresh, status: _)) {
      _stop();
      // Logged out while the link was out: the new tokens must not sign this
      // device back in behind the user's back.
      if (ref.read(authProvider) is! SignedIn) {
        state = const EmailIdle();
        return;
      }
      await ref.read(tokenStoreProvider).save(accessToken: access, refreshToken: refresh);
      ref.invalidate(profileProvider);
      if (ref.mounted) state = EmailIdle(note: 'Your account now uses ${waiting.email}.');
      return;
    }
    if (answer.status case 'expired' || 'denied' || 'dead') {
      _stop();
      state = const EmailIdle(note: "The link wasn't used. Nothing changed.");
    }
  }
}

/// One sign-in of this account (`GET /v1/auth/sign_ins`).
typedef SignInRecord = ({DateTime at, String device, String network, String method});

final signInHistoryProvider = FutureProvider.autoDispose<List<SignInRecord>>((ref) async {
  if (!ref.watch(authProvider).hasAccount) return const [];
  final rows = await ref.read(apiClientProvider).getJsonList('v1/auth/sign_ins', authenticated: true);
  return [
    for (final r in rows)
      if (r case {
        'at': final int at,
        'device_name': final String d,
        'ip_prefix': final String ip,
        'method': final String m,
      })
        (at: DateTime.fromMillisecondsSinceEpoch(at * 1000), device: d, network: ip, method: m),
  ];
});
