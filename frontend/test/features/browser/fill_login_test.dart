import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:every_ai/features/code/harness/everyai/browser_io.dart';
import 'package:every_ai/features/code/harness/everyai/screen_tools_io.dart';
import 'package:every_ai/features/code/harness/everyai/tools_io.dart' show ToolOutput;
import 'package:every_ai/features/code/live/agent_logins.dart';
import 'package:every_ai/features/code/live/browser_jar.dart';
import 'package:flutter_test/flutter_test.dart';

/// Signs in to a local page with a saved login on a real headless Chrome; skipped where none is installed.
void main() {
  final chrome = HeadlessBrowser.find();
  late Directory tmp;
  late HeadlessBrowser browser;
  late AgentLogins store;

  const password = 'correct-horse-77';

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('fill');
    browser = HeadlessBrowser(profileDir: '${tmp.path}/profile');
    store = AgentLogins(SealedStore('${tmp.path}/sealed', () async => SecretKey(List.filled(32, 5))));
    await store.save(
      name: 'local',
      url: 'http://localhost/login',
      username: 'ada',
      password: password,
      scope: LoginScope.global,
    );
  });
  tearDown(() async {
    await browser.close();
    await browser.host.stop();
    tmp.deleteSync(recursive: true);
  });

  Future<String> run(Map<String, Object?> args, LoginAccess access) async {
    final out = await runBrowser(browser, args, root: tmp.path, vision: false, fit: (t, _) => t, logins: access);
    expect(out.text, isNot(contains(password)));
    return out.text;
  }

  group('checked again right before typing', () {
    late HttpServer server;
    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((r) {
        r.response.headers.contentType = ContentType.html;
        r.response.write(
          '<!doctype html><title>Sign in</title><form><input id="user"><input id="pw" type="password"></form>',
        );
        r.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    // The login is for localhost; 127.0.0.1 is another site to the "fill on any site" switch.
    String at(String host) => 'http://$host:${server.port}/login';

    Future<ToolOutput> fill(LoginAccess access) => runBrowser(
      browser,
      {'action': 'fill_login', 'login': 'local', 'selector': '#pw'},
      root: tmp.path,
      vision: false,
      fit: (t, _) => t,
      logins: access,
    );

    Future<void> asking(LoginGate gate) async {
      for (var i = 0; i < 100 && gate.stateOf('local') is! ConsentAsking; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(gate.stateOf('local'), isA<ConsentAsking>());
    }

    test(
      'own site only, asking first: a page that went elsewhere during the wait gets nothing',
      () async {
        final gate = LoginGate.of('fill-redirect');
        final access = LoginAccess(
          policy: const LoginPolicy(anySite: false, withoutAsking: false),
          logins: () async => store,
          gate: gate,
        );
        await run({'action': 'open', 'url': at('localhost')}, access);
        final pending = fill(access);
        await asking(gate);
        // A redirect while the card waits.
        await browser.evaluate('location.href = ${'"${at('127.0.0.1')}"'}');
        for (var i = 0; i < 50 && await browser.evaluate('location.hostname') != '127.0.0.1'; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        gate.answer('local', allow: true);
        final out = await pending;
        expect(out.isError, isTrue);
        expect(out.text, contains('this page is on 127.0.0.1'));
        expect(out.text, contains('Nothing was typed'));
        expect(await browser.evaluate('document.getElementById("pw").value'), '');
      },
      skip: chrome == null ? 'no Chrome installed' : null,
      timeout: const Timeout(Duration(minutes: 1)),
    );
  });
}
