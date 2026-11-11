import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:every_ai/features/code/harness/everyai/browser_io.dart';
import 'package:every_ai/features/code/harness/everyai/screen_tools_io.dart';
import 'package:every_ai/features/code/live/agent_logins.dart';
import 'package:every_ai/features/code/live/browser_jar.dart';
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
}
