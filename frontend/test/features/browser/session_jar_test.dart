import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:every_ai/features/code/harness/everyai/browser_io.dart';
import 'package:every_ai/features/code/harness/everyai/llm.dart';
import 'package:every_ai/features/code/harness/everyai/shell_io.dart';
import 'package:every_ai/features/code/harness/everyai/tools_io.dart';
import 'package:every_ai/features/code/live/browser_jar.dart';
import 'package:every_ai/features/code/live/login_wall.dart';
import 'package:flutter_test/flutter_test.dart';

/// Each session's own cookie jar, saved logins and the login wall, on a real headless Chrome.
void main() {
  final chrome = HeadlessBrowser.find();
  final skip = chrome == null ? 'no Chrome installed' : null;
  late Directory tmp;
  late HttpServer server;
  late SealedStore store;
  final open = <HeadlessBrowser>[];

  HeadlessBrowser session(String name) {
    final b = HeadlessBrowser(
      profileDir: '${tmp.path}/profile',
      jarHome: (store: () async => store, name: 'jar-$name'),
    );
    open.add(b);
    return b;
  }

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('session-jar');
    store = SealedStore('${tmp.path}/sealed', () async => SecretKey(List.filled(32, 3)));
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) {
      final signedIn = (r.cookies.where((c) => c.name == 'sid').firstOrNull?.value) ?? '';
      final page = switch (r.uri.path) {
        '/welcome' => () {
          r.response.cookies.add(Cookie('sid', r.uri.queryParameters['as'] ?? 'u')..httpOnly = true);
          return '<title>Signed in</title>ok';
        }(),
        '/login' => '<title>Sign in</title><form><input name="u"><input type="password" name="p"></form>',
        _ => '<title>Home</title><p id="who">${signedIn.isEmpty ? 'nobody' : signedIn}</p>',
      };
      r.response.headers.contentType = ContentType.html;
      r.response.write('<!doctype html>$page');
      r.response.close();
    });
  });
  tearDown(() async {
    for (final b in open) {
      await b.close();
    }
    if (open.isNotEmpty) await open.first.host.stop();
    open.clear();
    await server.close(force: true);
    wallOnLocalPages = false;
    tmp.deleteSync(recursive: true);
  });
  String url(String path) => 'http://localhost:${server.port}$path';
  Future<Object?> who(HeadlessBrowser b) async {
    await b.open(url('/'));
    return b.evaluate('document.getElementById("who").textContent');
  }

  test(
    "sessions don't share sign-ins; a session's jar (cookies and storage) comes back after it closes",
    () async {
      final a = session('a'), b = session('b');
      await a.open(url('/welcome?as=ada'));
      expect(await who(a), 'ada');
      expect(await who(b), 'nobody');
      await a.evaluate('localStorage.setItem("token", "jwt-1")');
      await a.close();
      open.remove(a);
      final again = session('a');
      expect(await who(again), 'ada');
      expect(await again.evaluate('localStorage.getItem("token")'), 'jwt-1');
      expect(again.signedInSites, ['localhost']);
      // A sign-out takes the site out of the jar and the browser.
      await again.clearJar(site: 'localhost');
      expect(await who(again), 'nobody');
      // And stays signed out: nothing writes the token back.
      await again.reload();
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(await again.evaluate('localStorage.getItem("token")'), isNull);
      await again.close();
      open.remove(again);
      final third = session('a');
      await third.open(url('/'));
      expect(await third.evaluate('localStorage.getItem("token")'), isNull);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'a saved login signs another session in; a removed session leaves no jar',
    () async {
      final a = session('a'), b = session('b');
      await a.open(url('/welcome?as=grace'));
      final logins = SavedLogins(store);
      final saved = await logins.save(
        'localhost',
        jarForSite(await a.captureJar(), 'localhost'),
        scope: LoginScope.project,
        projectId: 'p',
      );
      await b.open(url('/'));
      await b.applyJar((await logins.payload(saved.id))!, site: 'localhost', loginId: saved.id);
      expect(await who(b), 'grace');
      expect(b.usedLogins, {'localhost': saved.id});
      await b.forgetJar();
      await b.close();
      expect(await store.read('jar-b'), isNull);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'the agent waits at a sign-in page until the user signs in, or skips',
    () async {
      wallOnLocalPages = true;
      final b = session('w');
      final runner = ToolRunner(
        root: tmp.path,
        shell: SessionShell(root: tmp.path, sessionTag: 't', scratchDir: '${tmp.path}/.sh'),
        gateway: GatewayClient(baseUrl: 'http://127.0.0.1:9/v1', apiKey: ''),
        sessionTag: 't',
        vision: false,
        browser: b,
      );
      final waiting = runner.run('browser', {'action': 'open', 'url': url('/login')});
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(b.loginWall.state.value, isA<WallWaiting>());
      expect((b.loginWall.state.value as WallWaiting).site, 'localhost');
      // The user signs in (in the Preview): the page moves on.
      await b.userOpen(url('/welcome?as=linus'));
      final done = await waiting;
      expect(done.text, contains('the user took care of it'));
      expect(b.loginWall.state.value, isA<WallIdle>());

      final again = runner.run('browser', {'action': 'open', 'url': url('/login')});
      await Future<void>.delayed(const Duration(seconds: 2));
      b.loginWall.skip();
      expect((await again).text, contains('chose to carry on without signing in'));
      // Skipped: that site doesn't hold the agent again.
      final third = await runner.run('browser', {'action': 'snapshot'});
      expect(third.text, isNot(contains('sign in')));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
