import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:every_ai/features/code/harness/everyai/browser_io.dart';
import 'package:every_ai/features/code/harness/everyai/screen_tools_io.dart';
import 'package:every_ai/features/code/harness/everyai/tools_io.dart' show ToolOutput;
import 'package:every_ai/features/code/live/agent_logins.dart';
import 'package:every_ai/features/code/live/browser_jar.dart';
import 'package:every_ai/features/code/live/live_browsers.dart';
import 'package:every_ai/features/code/ui/panes/browser_logins.dart' show fillPageWithLogin;
import 'package:flutter_test/flutter_test.dart';

/// Signs in to a local page with a saved login on a real headless Chrome; skipped where none is installed.
void main() {
  final chrome = HeadlessBrowser.find();
  late Directory tmp;
  late HeadlessBrowser browser;
  late AgentLogins store;
  late String url;
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
    // The page shows what it got (as a careless app might): the result must still not.
    url =
        (File('${tmp.path}/login.html')..writeAsStringSync('''
<!doctype html><title>Sign in</title>
<form id="f"><input id="user" autocomplete="username"><input id="pw" type="password"><button id="go">Sign in</button></form>
<p id="echo"></p>
<script>
document.getElementById('f').addEventListener('submit', (e) => {
  e.preventDefault();
  const ok = document.getElementById('user').value === 'ada' && document.getElementById('pw').value === '$password';
  document.title = ok ? 'Welcome' : 'Wrong';
  document.getElementById('echo').textContent = 'You typed ' + document.getElementById('pw').value;
  console.log('pw', document.getElementById('pw').value);
});
</script>'''))
            .uri
            .toString();
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

  test(
    'fill_login signs in; with the field switch off plain type is still refused',
    () async {
      final hidden = <String>[];
      final access = LoginAccess(
        policy: const LoginPolicy(secretFields: false),
        logins: () async => store,
        gate: LoginGate.of('fill-test'),
        hide: hidden.add,
      );
      await run({'action': 'open', 'url': url}, access);
      final listed = await run({'action': 'logins'}, access);
      expect(listed, contains('- local · localhost · user ada'));
      final typed = await runBrowser(
        browser,
        {'action': 'type', 'selector': '#pw', 'text': 'guess'},
        root: tmp.path,
        vision: false,
        fit: (t, _) => t,
        logins: access,
      );
      expect(typed.isError, isTrue);
      expect(typed.text, contains('Refused: the field is a password field'));
      expect(
        await run({'action': 'fill_login', 'login': 'local', 'field': 'username', 'selector': '#user'}, access),
        contains("Filled the username of 'local' into #user."),
      );
      final signed = await run({
        'action': 'fill_login',
        'login': 'local',
        'selector': '#pw',
        'submit': true,
        'snapshot': true,
      }, access);
      expect(signed, contains("Filled the password of 'local' into #pw and pressed Enter."));
      expect(await browser.evaluate('document.title'), 'Welcome');
      // The page echoed it and logged it: hidden in the result, and handed to the session's scrubber.
      expect(signed, contains('[EVERYAI-HIDDEN: saved login]'));
      expect(hidden, [password]);
      final unknown = await run({'action': 'fill_login', 'login': 'nope'}, access);
      expect(unknown, contains('Saved logins: local (localhost)'));
      // Own site only: a file page is no site of the login's.
      final strict = LoginAccess(policy: const LoginPolicy(anySite: false), logins: () async => store);
      expect(
        await run({'action': 'fill_login', 'login': 'local', 'selector': '#pw'}, strict),
        contains('is for localhost'),
      );
    },
    skip: chrome == null ? 'no Chrome installed' : null,
    timeout: const Timeout(Duration(minutes: 1)),
  );

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

    test(
      'Take control during the wait: nothing is typed',
      () async {
        final gate = LoginGate.of('fill-take');
        final access = LoginAccess(
          policy: const LoginPolicy(withoutAsking: false),
          logins: () async => store,
          gate: gate,
        );
        await run({'action': 'open', 'url': at('localhost')}, access);
        final pending = fill(access);
        await asking(gate);
        browser.control.take();
        gate.answer('local', allow: true);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        browser.control.giveBack();
        final out = await pending;
        expect(out.isError, isTrue);
        expect(out.text, contains('took control'));
        expect(await browser.evaluate('document.getElementById("pw").value'), '');
      },
      skip: chrome == null ? 'no Chrome installed' : null,
      timeout: const Timeout(Duration(minutes: 1)),
    );

    test(
      "the Preview key menu's fill is hidden from the agent like its own",
      () async {
        LiveBrowsers.debugSet('fill-menu', browser);
        addTearDown(() => LiveBrowsers.debugSet('fill-menu', null));
        await browser.open(at('localhost'));
        expect(await fillPageWithLogin(browser, store.entries.value.single, store), contains('password'));
        final access = LoginAccess(logins: () async => store, gate: LoginGate.of('fill-menu'));
        final read = await runBrowser(
          browser,
          {'action': 'eval', 'script': 'document.getElementById("pw").value'},
          root: tmp.path,
          vision: false,
          fit: (t, _) => t,
          logins: access,
        );
        expect(read.text, isNot(contains(password)));
        expect(read.text, contains('[EVERYAI-HIDDEN: saved login]'));
      },
      skip: chrome == null ? 'no Chrome installed' : null,
      timeout: const Timeout(Duration(minutes: 1)),
    );
  });
}
