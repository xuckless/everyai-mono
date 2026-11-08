import 'dart:async';

import 'package:every_ai/core/config/app_config.dart';
import 'package:every_ai/core/links/app_link.dart';
import 'package:every_ai/core/net/api_client.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/auth/auth_providers.dart';
import 'package:every_ai/features/auth/data/token_store.dart';
import 'package:every_ai/features/auth/email_change.dart';
import 'package:every_ai/features/auth/data/magic_api.dart';
import 'package:every_ai/features/auth/domain/auth_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A server for the magic-link endpoints the test drives by hand.
final class _FakeMagic implements MagicApi {
  final asks = <String>[];
  var pollStatus = 'pending';
  String? pollToken;
  String rightCode = '123456';
  int wrong = 0;
  Completer<void>? holdAsk;
  Completer<void>? holdCode;

  @override
  Future<MagicAsk> ask(String email, {required String deviceName}) async {
    asks.add(email);
    await holdAsk?.future;
    return (requestId: 'r${asks.length}', secret: 's', expiresAt: DateTime.now().add(const Duration(minutes: 15)));
  }

  @override
  Future<MagicAnswer> poll(String requestId, String secret) async =>
      (status: pollStatus, accessToken: pollToken, refreshToken: pollToken == null ? null : 'rt');

  @override
  Future<MagicAnswer> code(String requestId, String secret, String code) async {
    await holdCode?.future;
    if (code == rightCode) return (status: 'redeemed', accessToken: 'at', refreshToken: 'rt');
    wrong++;
    throw WrongCode(dead: wrong >= 5);
  }
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  ProviderContainer make(_FakeMagic api, {List<Override> more = const []}) {
    final c = ProviderContainer(
      overrides: [
        ...more,
        magicApiProvider.overrideWithValue(api),
        magicPollIntervalProvider.overrideWithValue(const Duration(milliseconds: 10)),
        signInDeviceNameProvider.overrideWithValue('Test Mac'),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<void> settle(ProviderContainer c) async {
    // Restoring → SignedOut (no stored refresh token).
    for (var i = 0; i < 20 && c.read(authProvider) is Restoring; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('email, then the code signs in; a wrong code stays on the inbox with a note', () async {
    final api = _FakeMagic();
    final c = make(api);
    await settle(c);
    expect(c.read(authProvider), isA<SignedOut>());
    final auth = c.read(authProvider.notifier);
    auth.startSignIn();
    expect((c.read(authProvider) as SigningIn).flow, isA<EnterEmail>());
    await auth.ask('ada@example.com');
    expect((c.read(authProvider) as SigningIn).flow, isA<Waiting>());

    await auth.enterCode('000000');
    final after = (c.read(authProvider) as SigningIn).flow;
    expect(after, isA<Waiting>());
    expect((after as Waiting).codeError, isNotNull);

    await auth.enterCode('123456');
    expect(c.read(authProvider), isA<SignedIn>());
  });

  test('the link pressed elsewhere signs this device in through its poll', () async {
    final api = _FakeMagic();
    final c = make(api);
    await settle(c);
    final auth = c.read(authProvider.notifier);
    await auth.ask('ada@example.com');
    api.pollToken = 'at';
    api.pollStatus = 'redeemed';
    for (var i = 0; i < 50 && c.read(authProvider) is! SignedIn; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(c.read(authProvider), isA<SignedIn>());
  });

  test('a refused or expired request ends the flow with the reason', () async {
    final api = _FakeMagic();
    final c = make(api);
    await settle(c);
    final auth = c.read(authProvider.notifier);
    await auth.ask('ada@example.com');
    api.pollStatus = 'denied';
    await auth.pollNow();
    final flow = (c.read(authProvider) as SigningIn).flow;
    expect(flow, isA<Expired>());
    expect((flow as Expired).reason, contains('Not me'));
  });

  test('five wrong codes end the request', () async {
    final api = _FakeMagic();
    final c = make(api);
    await settle(c);
    final auth = c.read(authProvider.notifier);
    await auth.ask('ada@example.com');
    for (var i = 0; i < 5; i++) {
      await auth.enterCode('000000');
    }
    expect((c.read(authProvider) as SigningIn).flow, isA<Expired>());
  });

  test('an answer that lands after Cancel is dropped', () async {
    final api = _FakeMagic()..holdAsk = Completer<void>();
    final c = make(api);
    await settle(c);
    final auth = c.read(authProvider.notifier);
    final asking = auth.ask('ada@example.com');
    expect((c.read(authProvider) as SigningIn).flow, isA<Requesting>());
    auth.cancelSignIn();
    api.holdAsk!.complete();
    await asking;
    expect(c.read(authProvider), isA<SignedOut>());
  });

  test('everyai://auth brings the app forward and carries nothing', () {
    expect(parseAppLink(Uri.parse('everyai://auth')), isA<SignInLink>());
    expect(parseAppLink(Uri.parse('everyai://auth?token=x')), isA<SignInLink>());
  });

  test('a pending poll while a code is checked keeps Verifying, so a wrong code still shows', () async {
    final api = _FakeMagic()..holdCode = Completer<void>();
    final c = make(api);
    await settle(c);
    final auth = c.read(authProvider.notifier);
    auth.startSignIn();
    await auth.ask('ada@example.com');
    final checking = auth.enterCode('000000');
    expect((c.read(authProvider) as SigningIn).flow, isA<Verifying>());
    await auth.pollNow();
    expect((c.read(authProvider) as SigningIn).flow, isA<Verifying>());
    api.holdCode!.complete();
    await checking;
    final flow = (c.read(authProvider) as SigningIn).flow;
    expect(flow, isA<Waiting>());
    expect((flow as Waiting).codeError, isNotNull);
  });

  test('Sign in while the stored session is still being restored is ignored', () async {
    FlutterSecureStorage.setMockInitialValues({'everyai.refresh_token': 'rt'});
    final refresh = Completer<http.Response>();
    await http.runWithClient(() async {
      final c = make(_FakeMagic());
      c.read(authProvider.notifier).startSignIn();
      expect(c.read(authProvider), isA<Restoring>());
      refresh.complete(http.Response('{"access_token":"a","refresh_token":"rt2"}', 200));
      await settle(c);
      expect(c.read(authProvider), isA<SignedIn>());
    }, () => MockClient((_) => refresh.future));
  });

  test('a stored session survives a server that is still waking up', () async {
    FlutterSecureStorage.setMockInitialValues({'everyai.refresh_token': 'rt'});
    await http.runWithClient(() async {
      final c = make(_FakeMagic());
      c.read(authProvider);
      await settle(c);
      // Not signed out while its token is kept and sent: the user can still log out.
      expect(c.read(authProvider), isA<SignedIn>());
    }, () => MockClient((_) async => http.Response('waking', 503)));
  });

  test('a refresh token the server refuses signs this device out', () async {
    FlutterSecureStorage.setMockInitialValues({'everyai.refresh_token': 'rt'});
    var refused = false;
    await http.runWithClient(() async {
      final c = make(_FakeMagic());
      c.read(authProvider);
      await settle(c);
      expect(c.read(authProvider), isA<SignedIn>());
      refused = true;
      expect(await c.read(tokenStoreProvider).refreshAccessToken(), isNull);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(authProvider), isA<SignedOut>());
      expect(await c.read(tokenStoreProvider).readRefreshToken(), isNull);
    }, () => MockClient((_) async => refused ? http.Response('', 401) : http.Response('{"access_token":"a"}', 200)));
  });

  test('a refresh that lands after sign-out leaves no token behind', () async {
    FlutterSecureStorage.setMockInitialValues({'everyai.refresh_token': 'rt'});
    final answer = Completer<http.Response>();
    await http.runWithClient(() async {
      final store = TokenStore(AppConfig(apiBaseUrl: _base, devTools: false, sseEnabled: true));
      final refreshing = store.refreshAccessToken();
      await Future<void>.delayed(Duration.zero);
      await store.clear();
      answer.complete(http.Response('{"access_token":"a2","refresh_token":"rt2"}', 200));
      expect(await refreshing, isNull);
      expect(await store.readRefreshToken(), isNull);
      expect(store.hasValidAccessToken, isFalse);
    }, () => MockClient((_) => answer.future));
  });

  test('an email change link that lands after sign-out signs nothing back in', () async {
    final api = _FakeMagic();
    final c = make(
      api,
      more: [
        apiClientProvider.overrideWithValue(
          ApiClient(
            baseUrl: _base,
            client: MockClient((_) async => http.Response('{"request_id":"e1","request_secret":"s"}', 202)),
          ),
        ),
      ],
    );
    await settle(c);
    expect(c.read(authProvider), isA<SignedOut>());
    final sub = c.listen(emailChangeProvider, (_, _) {});
    addTearDown(sub.close);
    await c.read(emailChangeProvider.notifier).send('new@example.com');
    expect(c.read(emailChangeProvider), isA<EmailAwaitingLink>());
    api.pollToken = 'at';
    api.pollStatus = 'redeemed';
    for (var i = 0; i < 50 && c.read(emailChangeProvider) is EmailAwaitingLink; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await c.read(tokenStoreProvider).readRefreshToken(), isNull);
    expect(c.read(authProvider), isA<SignedOut>());
  });
}

final _base = Uri.parse('http://localhost:1');
