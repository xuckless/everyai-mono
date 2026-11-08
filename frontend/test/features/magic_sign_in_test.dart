import 'dart:async';

import 'package:every_ai/core/links/app_link.dart';
import 'package:every_ai/features/auth/auth_providers.dart';
import 'package:every_ai/features/auth/data/magic_api.dart';
import 'package:every_ai/features/auth/domain/auth_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// A server for the magic-link endpoints the test drives by hand.
final class _FakeMagic implements MagicApi {
  final asks = <String>[];
  var pollStatus = 'pending';
  String? pollToken;
  String rightCode = '123456';
  int wrong = 0;
  Completer<void>? holdAsk;

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
    if (code == rightCode) return (status: 'redeemed', accessToken: 'at', refreshToken: 'rt');
    wrong++;
    throw WrongCode(dead: wrong >= 5);
  }
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  ProviderContainer make(_FakeMagic api) {
    final c = ProviderContainer(
      overrides: [
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
}
