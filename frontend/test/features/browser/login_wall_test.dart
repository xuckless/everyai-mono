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

  test(
    'a wait ends when the page is past the sign-in, on Skip (and that site waits no more), or at the limit',
    () async {
      final wall = LoginWall();
      var at = (url: 'https://github.com/login', password: true);
      final passed = wall.hold('github.com', at.url, probe: () async => at, every: const Duration(milliseconds: 10));
      expect(wall.state.value, isA<WallWaiting>());
      expect(LoginWall.waiting.value, contains(wall));
      // A second call joins the first.
      final joined = wall.hold('github.com', at.url, probe: () async => at);
      at = (url: 'https://github.com/', password: false);
      expect(await passed, WallOutcome.passed);
      expect(await joined, WallOutcome.passed);
      expect(wall.state.value, isA<WallIdle>());
      expect(LoginWall.waiting.value, isNot(contains(wall)));

      at = (url: 'https://github.com/login', password: true);
      final skipped = wall.hold('github.com', at.url, probe: () async => at, every: const Duration(milliseconds: 10));
      wall.skip();
      expect(await skipped, WallOutcome.skipped);
      expect(wall.skipped('github.com'), isTrue);

      final late = wall.hold(
        'gitlab.com',
        'https://gitlab.com/users/sign_in',
        probe: () async => (url: 'https://gitlab.com/users/sign_in', password: true),
        every: const Duration(milliseconds: 10),
        timeout: const Duration(milliseconds: 50),
      );
      expect(await late, WallOutcome.timedOut);
      final stopped = wall.hold('x.com', 'https://x.com/login', probe: () async => null);
      wall.stop();
      expect(await stopped, WallOutcome.stopped);
    },
  );

  test('cookies for a site, expired ones dropped; storage seeds only an empty storage', () {
    final now = DateTime.utc(2026, 11, 7);
    final at = now.millisecondsSinceEpoch / 1000;
    final jar = (
      cookies: <Map<String, Object?>>[
        {'name': 'a', 'value': '1', 'domain': '.github.com', 'path': '/', 'expires': at + 3600, 'httpOnly': true},
        {'name': 'b', 'value': '2', 'domain': 'gist.github.com', 'path': '/', 'expires': -1, 'session': true},
        {'name': 'old', 'value': '3', 'domain': 'github.com', 'path': '/', 'expires': at - 10},
        {'name': 'c', 'value': '4', 'domain': 'example.com', 'path': '/', 'expires': -1},
      ],
      storage: <String, Map<String, String>>{
        'https://github.com': {'t': 'x'},
        'https://example.com': {'u': 'y'},
      },
    );
    final gh = jarForSite(jar, 'github.com');
    expect([for (final c in gh.cookies) c['name']], ['a', 'b', 'old']);
    expect(gh.storage.keys, ['https://github.com']);
    expect([for (final c in gh.cookies) ?cookieParam(c, now: now)].map((c) => c['name']), ['a', 'b']);
    expect(cookieParam(gh.cookies[1], now: now)!.containsKey('expires'), isFalse);
    expect(jarSites(jar), ['github.com', 'example.com']);
    expect(jarWithoutSite(jar, 'github.com').cookies.single['name'], 'c');
    final merged = jarMerged(jar, (
      cookies: [
        {'name': 'c', 'value': 'new', 'domain': 'example.com', 'path': '/'},
      ],
      storage: {
        'https://example.com': {'v': 'z'},
      },
    ));
    expect(merged.cookies.firstWhere((c) => c['name'] == 'c')['value'], 'new');
    expect(merged.storage['https://example.com'], {'u': 'y', 'v': 'z'});
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
    await logins.writeBack(p.id, (
      cookies: [
        {'name': 'sid', 'value': 'v2', 'domain': 'github.com', 'path': '/'},
      ],
      storage: const {},
    ));
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
  });
}
