import 'package:every_ai/features/code/live/browser_jar.dart';
import 'package:every_ai/features/code/live/login_wall.dart';
import 'package:cryptography/cryptography.dart';

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sign-in pages: password fields, sign-in services and paths; never local pages', () {
    expect(loginWallSite('https://github.com/login', password: true), 'github.com');
    expect(loginWallSite('https://gist.github.com/', password: true), 'github.com');
    expect(loginWallSite('https://accounts.google.com/v3/signin/identifier', password: false), 'google.com');
    expect(loginWallSite('https://acme.okta.com/app', password: false), 'acme.okta.com');
    expect(loginWallSite('https://example.com/users/sign_in', password: false), 'example.com');
    expect(loginWallSite('https://example.com/docs/authentication', password: false), isNull);
    // Docs and APIs under /auth, /oauth2 or /sessions are no sign-in page.
    expect(loginWallSite('https://supabase.com/docs/guides/auth', password: false), isNull);
    expect(loginWallSite('https://developers.google.com/identity/protocols/oauth2', password: false), isNull);
    expect(loginWallSite('https://conf.example/sessions', password: false), isNull);
    expect(loginWallSite('https://example.com/sso/start', password: false), 'example.com');
    expect(loginWallSite('https://example.com/', password: false), isNull);
    expect(loginWallSite('http://localhost:3000/login', password: true), isNull);
    expect(loginWallSite('http://127.0.0.1:3000/login', password: true), isNull);
    expect(loginWallSite('file:///tmp/a.html', password: true), isNull);
    expect(siteOf('www.bbc.co.uk'), 'bbc.co.uk');
    expect(siteOf('.github.com'), 'github.com');
    expect(siteOf('10.0.0.2'), '10.0.0.2');
    // Shared hosts: each app is its own site.
    expect(siteOf('alice.github.io'), 'alice.github.io');
    expect(siteOf('www.my-app.vercel.app'), 'my-app.vercel.app');
    expect(siteOf('vercel.app'), 'vercel.app');
  });

  test('sealed files open only with their key; saved logins by scope, expiry and write-back', () async {
    final dir = Directory.systemTemp.createTempSync('sealed');
    addTearDown(() => dir.deleteSync(recursive: true));
    final key = SecretKey(List.filled(32, 7));
    final store = SealedStore(dir.path, () async => key);
    await store.write('jar-s1', {'a': 1});
    expect(await store.read('jar-s1'), {'a': 1});
    final raw = File('${dir.path}/jar-s1.sealed').readAsBytesSync();
    expect(String.fromCharCodes(raw).contains('"a"'), isFalse);
    expect(await SealedStore(dir.path, () async => SecretKey(List.filled(32, 8))).read('jar-s1'), isNull);

    final logins = SavedLogins(store);
    final data = (
      cookies: <Map<String, Object?>>[
        {'name': 'sid', 'value': 'v1', 'domain': 'github.com', 'path': '/'},
      ],
      storage: <String, Map<String, String>>{},
    );
    final p = await logins.save('github.com', data, scope: LoginScope.project, projectId: 'p1');
    final g = await logins.save('github.com', data, scope: LoginScope.global);
    expect(logins.usable('p1', site: 'github.com').map((l) => l.id), [p.id, g.id]);
    expect(logins.usable('p2', site: 'github.com').map((l) => l.id), [g.id]);
    // Saving again for the same site and scope replaces it.
    await logins.save('github.com', data, scope: LoginScope.project, projectId: 'p1');
    expect(logins.logins.value, hasLength(2));
    await logins.markExpired(p.id);
    expect(logins.logins.value.firstWhere((l) => l.id == p.id).expired, isTrue);
    final v2 = (
      cookies: [
        {'name': 'sid', 'value': 'v2', 'domain': 'github.com', 'path': '/'},
      ],
      storage: const <String, Map<String, String>>{},
    );
    // A write-back keeps the expiry; only a sign-in past the wall (renewed) clears it.
    await logins.writeBack(p.id, v2);
    expect(logins.logins.value.firstWhere((l) => l.id == p.id).expired, isTrue);
    await logins.writeBack(p.id, v2, renewed: true);
    expect(logins.logins.value.firstWhere((l) => l.id == p.id).expired, isFalse);
    expect((await logins.payload(p.id))!.cookies.single['value'], 'v2');
    // A signed-out session doesn't wipe the saved login.
    await logins.writeBack(p.id, emptyJar);
    expect((await logins.payload(p.id))!.cookies.single['value'], 'v2');
    final reloaded = SavedLogins(store);
    await reloaded.load();
    expect(reloaded.logins.value, hasLength(2));
    await reloaded.delete(g.id);
    expect(await reloaded.payload(g.id), isNull);
    // A removed project's own logins go; logins for every project stay.
    final g2 = await reloaded.save('github.com', data, scope: LoginScope.global);
    await reloaded.forgetProject('p1');
    expect(reloaded.logins.value.map((l) => l.id), [g2.id]);
    expect(await reloaded.payload(p.id), isNull);
  });

  test('sealed writes to one name at once never leave a half-written file', () async {
    final dir = Directory.systemTemp.createTempSync('sealed');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = SealedStore(dir.path, () async => SecretKey(List.filled(32, 7)));
    final big = List.generate(2000, (i) => 'value $i ' * 10);
    await Future.wait([
      for (var i = 0; i < 12; i++) store.write('jar-q', {'n': i, 'big': big}),
    ]);
    final j = await store.read('jar-q') as Map;
    expect(j['n'], 11);
    expect(dir.listSync().where((f) => f.path.endsWith('.tmp')), isEmpty);
  });
}
