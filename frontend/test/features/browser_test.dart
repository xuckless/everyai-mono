import 'dart:io';

import 'package:every_ai/features/code/harness/everyai/browser_io.dart';
import 'package:every_ai/features/code/harness/everyai/llm.dart';
import 'package:every_ai/features/code/harness/everyai/screen_windows.dart';
import 'package:every_ai/features/code/harness/everyai/shell_io.dart';
import 'package:every_ai/features/code/harness/everyai/tools_io.dart';
import 'package:every_ai/features/code/live/agent_logins.dart';
import 'package:flutter_test/flutter_test.dart';

/// Drives a real headless Chrome; skipped where none is installed.
void main() {
  final chrome = HeadlessBrowser.find();
  late Directory tmp;
  late HeadlessBrowser browser;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('browser');
    browser = HeadlessBrowser(profileDir: '${tmp.path}/profile');
  });
  tearDown(() async {
    await browser.close();
    // Chrome outlives a closed page for a while (other sessions of the project may want it): stop it here.
    await browser.host.stop();
    tmp.deleteSync(recursive: true);
  });

  // The browser itself guards those fields; the tool lifts the guard while the user lets agents type into them
  // (Settings > Code > Logins, on by default).
  group('password and payment fields', () {
    late String url;
    setUp(() {
      url =
          (File('${tmp.path}/forms.html')..writeAsStringSync('''
<!doctype html><title>Forms</title>
<form id="login" action="done.html"><input id="user"><input id="pw" type="password"><button id="signin">Sign in</button></form>
<form id="pay" action="done.html"><input id="cc" autocomplete="cc-number"><input id="cvv" name="cvv2"><input id="iban" name="iban"></form>
<form id="search" action="done.html"><input id="q" name="q"><button id="go" style="width:80px;height:30px">Go</button></form>
<input id="name"><input id="cardtitle" name="card-title">
<iframe id="stripe" title="Secure card payment input frame" srcdoc="<input>"></iframe>
'''))
              .uri
              .toString();
      File('${tmp.path}/done.html').writeAsStringSync('<!doctype html><title>Done</title>');
    });
    Future<Object?> value(String id) => browser.evaluate('document.getElementById("$id").value');

    test(
      'type, press and click',
      () async {
        await browser.open(url);
        for (final id in ['pw', 'cc', 'cvv', 'iban']) {
          await expectLater(
            browser.type('secret', selector: '#$id'),
            throwsA(isA<BrowserError>().having((e) => e.message, 'message', startsWith('Refused: the field is a '))),
          );
          expect(await value(id), '', reason: id);
        }
        // Plain fields, and "card" alone (a kanban card), still take text.
        await browser.type('Ada', selector: '#name');
        await browser.type('Todo', selector: '#cardtitle');
        expect([await value('name'), await value('cardtitle')], ['Ada', 'Todo']);
        // One character at a time is the same.
        await browser.click(selector: '#pw');
        await expectLater(browser.press('a'), throwsA(_refused));
        expect(await value('pw'), '');
        // The user name is fine, but Enter or the button would send the password's form.
        await browser.type('ada', selector: '#user');
        await expectLater(browser.press('Enter'), throwsA(_refused));
        await expectLater(browser.type('x', selector: '#user', submit: true), throwsA(_refused));
        await expectLater(browser.click(selector: '#signin'), throwsA(_refused));
        final at = await browser.evaluate(
          '(() => { const r = document.getElementById("signin").getBoundingClientRect(); '
          'return [r.left + r.width / 2, r.top + r.height / 2]; })()',
        );
        final xy = (at! as List).cast<num>();
        await expectLater(
          browser.click(x: xy[0].toDouble(), y: xy[1].toDouble()),
          throwsA(isA<BrowserError>().having((e) => e.message, 'message', contains('a password field'))),
        );
        // Space on the focused button presses it just the same.
        await browser.evaluate('document.getElementById("signin").focus()');
        await expectLater(
          browser.press('Space'),
          throwsA(isA<BrowserError>().having((e) => e.message, 'message', contains('Space would press a button'))),
        );
        expect(await browser.describe(), startsWith('Forms'));
        // A payment frame we can't look into counts by its name.
        await browser.evaluate('document.getElementById("stripe").focus()');
        await expectLater(browser.type('4242'), throwsA(_refused));
        // A plain form submits.
        await browser.type('flutter', selector: '#q', submit: true);
        await browser.wait(selector: 'title');
        expect(await browser.evaluate('location.pathname.endsWith("done.html")'), isTrue);
      },
      skip: chrome == null ? 'no Chrome installed' : null,
      timeout: const Timeout(Duration(minutes: 1)),
    );

    test(
      'through the tool: typed by default, refused in plain words with the switch off',
      () async {
        final runner = _runner(tmp, browser);
        await runner.run('browser', {'action': 'open', 'url': url});
        final typed = await runner.run('browser', {'action': 'type', 'selector': '#pw', 'text': 'hunter2'});
        expect(typed.isError, isFalse, reason: typed.text);
        expect(await value('pw'), 'hunter2');
        final strict = _runner(tmp, browser, policy: const LoginPolicy(secretFields: false));
        final refused = await strict.run('browser', {'action': 'type', 'selector': '#cc', 'text': '4242'});
        expect(refused.isError, isTrue);
        expect(refused.text, contains('Refused: the field is a payment card field.'));
        expect(refused.text, contains('fill_login'));
      },
      skip: chrome == null ? 'no Chrome installed' : null,
      timeout: const Timeout(Duration(minutes: 1)),
    );
  });

  test('screenshot never takes a window this session did not start', () async {
    // The user's apps on screen; nothing of the session's among them.
    const windows = [
      (id: 1, pid: 10, owner: 'Mail', title: 'Inbox', width: 900, height: 700),
      (id: 2, pid: 11, owner: 'Notes', title: '', width: 600, height: 500),
      (id: 3, pid: 12, owner: '1Password', title: 'Vault', width: 700, height: 500),
    ];
    Future<WindowPick> pick({String? app}) => pickSessionWindow(
      windows,
      pids: const {99},
      root: tmp.path,
      executableOf: (pid) async => '/Applications/x.app/Contents/MacOS/x',
      app: app,
    );
    expect(await pick(), isA<NoWindow>());
    // Named, it is someone else's: the EveryAI harness only captures an OwnWindow.
    expect(await pick(app: 'mail'), isA<ForeignWindow>());
    // A password manager is never even foreign: the tool says it skipped it.
    final vault = await pick(app: '1password');
    expect((vault as NoWindow).skipped, ['1Password (a password manager)']);
    expect(skippedText(vault.skipped), startsWith('Skipped 1Password (a password manager): EveryAI never captures'));
  });
}

final _refused = isA<BrowserError>().having((e) => e.message, 'message', startsWith('Refused: '));

ToolRunner _runner(Directory tmp, HeadlessBrowser browser, {LoginPolicy policy = LoginPolicy.open}) => ToolRunner(
  root: tmp.path,
  shell: SessionShell(root: tmp.path, sessionTag: 't', scratchDir: '${tmp.path}/.sh'),
  gateway: GatewayClient(baseUrl: 'http://127.0.0.1:9/v1', apiKey: ''),
  sessionTag: 't',
  vision: true,
  browser: browser,
  logins: () => LoginAccess(policy: policy),
);
