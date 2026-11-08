import 'dart:io';

import 'package:every_ai/features/code/harness/everyai/browser_io.dart';
import 'package:every_ai/features/code/harness/everyai/llm.dart';
import 'package:every_ai/features/code/harness/everyai/screen_tools_io.dart';
import 'package:every_ai/features/code/harness/everyai/shell_io.dart';
import 'package:every_ai/features/code/harness/everyai/tools_io.dart';
import 'package:every_ai/features/code/ui/panes/browser_overlays.dart';
import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:flutter_test/flutter_test.dart';

/// Tabs, dialogs, file pickers, downloads, the right-click menu and find (real headless Chrome).
void main() {
  final chrome = HeadlessBrowser.find();
  final skip = chrome == null ? 'no Chrome installed' : null;
  late Directory tmp;
  late HeadlessBrowser browser;
  late HttpServer server;
  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('browser-features');
    browser = HeadlessBrowser(profileDir: '${tmp.path}/profile');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) {
      final page = switch (r.uri.path) {
        '/popup' => '<title>Sign in</title><button id="done" onclick="window.close()">Done</button>',
        '/file.txt' => null,
        '/alerting' => '<title>Alerting</title><script>setTimeout(() => alert("Hold on"), 50)</script>',
        '/framed' => '<title>Framed</title><iframe id="f" src="/inner"></iframe>',
        '/inner' => '<a id="dl" href="/file.txt" download>Get</a>',
        _ =>
          '<title>Home</title><p id="p">Find the needle and another needle.</p>'
              '<a id="pop" href="#" onclick="window.open(\'/popup\', \'auth\', \'width=500,height=600\'); return false">'
              'Sign in with X</a> <a id="newtab" href="/popup" target="_blank">New tab</a>'
              '<button id="ask" onclick="window.answer = confirm(\'Delete it?\')">Delete</button>'
              '<input id="up" type="file"><a id="dl" href="/file.txt" download>Get</a>',
      };
      if (page == null) {
        r.response.headers.contentType = ContentType.text;
        r.response.write('hello');
      } else {
        r.response.headers.contentType = ContentType.html;
        r.response.write('<!doctype html>$page');
      }
      r.response.close();
    });
  });
  tearDown(() async {
    // Bounded, so a hung browser still gets its Chrome stopped.
    await browser.close().timeout(const Duration(seconds: 10), onTimeout: () {});
    await browser.host.stop();
    await server.close(force: true);
    tmp.deleteSync(recursive: true);
  });
  String home() => 'http://localhost:${server.port}/';

  Future<void> until(bool Function() ok, {Duration within = const Duration(seconds: 5)}) async {
    final end = DateTime.now().add(within);
    while (!ok() && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  test(
    'a pop-up becomes the active tab; when it closes itself the page that opened it is active again',
    () async {
      await browser.open(home());
      final first = browser.activeTab;
      await browser.click(selector: '#pop');
      await until(() => browser.tabs.value.length == 2 && browser.activeTab != first);
      expect(browser.tabs.value, hasLength(2));
      await until(() => browser.page.value.title == 'Sign in');
      expect(await browser.evaluate('document.title'), 'Sign in');
      // Its Close button closes it: the click answers, or ends with the tab (whichever comes first), never a 30 s
      // wait.
      final sw = Stopwatch()..start();
      await browser.click(selector: '#done').then((_) {}, onError: (Object e) => expect(e, isA<TabClosedError>()));
      expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
      await until(() => browser.tabs.value.length == 1 && browser.activeTab == first);
      expect(browser.activeTab, first);
      expect(await browser.evaluate('document.title'), 'Home');
      // A target=_blank link too; switching back by hand.
      await browser.click(selector: '#newtab');
      await until(() => browser.tabs.value.length == 2);
      // Input while a switch is in flight waits for it instead of opening a page of its own.
      final switching = browser.switchTab(first!);
      await browser.userMouse('mouseMoved', 5, 5);
      await switching;
      expect(browser.tabs.value, hasLength(2));
      expect(await browser.evaluate('document.title'), 'Home');
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    "a confirm stops the agent's click with how to answer it; dialog answers it",
    () async {
      final runner = ToolRunner(
        root: tmp.path,
        shell: SessionShell(root: tmp.path, sessionTag: 't', scratchDir: '${tmp.path}/.sh'),
        gateway: GatewayClient(baseUrl: 'http://127.0.0.1:9/v1', apiKey: ''),
        sessionTag: 't',
        vision: false,
        browser: browser,
      );
      await runner.run('browser', {'action': 'open', 'url': home()});
      final clicked = await runner.run('browser', {'action': 'click', 'selector': '#ask'});
      expect(clicked.text, contains('asks to confirm: "Delete it?"'));
      expect(browser.dialog.value?.type, 'confirm');
      final blocked = await runner.run('browser', {'action': 'snapshot'});
      expect(blocked.isError, isTrue);
      final answered = await runner.run('browser', {'action': 'dialog', 'accept': false});
      expect(answered.text, contains('Dismissed the confirm "Delete it?"'));
      expect(await browser.evaluate('window.answer'), false);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'a click on a file input opens a picker the files go to; downloads are listed',
    () async {
      final file = File('${tmp.path}/cv.pdf')..writeAsStringSync('pdf');
      browser.downloadDir = '${tmp.path}/downloads';
      await browser.open(home());
      await browser.click(selector: '#up');
      await until(() => browser.fileChooser.value != null);
      expect(browser.fileChooser.value, isNotNull);
      await browser.setFiles([file.path]);
      expect(await browser.evaluate('document.getElementById("up").files[0].name'), 'cv.pdf');
      await browser.click(selector: '#dl');
      await until(() => browser.downloads.value.any((d) => d.state == 'completed'));
      final d = browser.downloads.value.single;
      expect((d.name, d.state), ('file.txt', 'completed'));
      expect(File(d.path!).readAsStringSync(), 'hello');
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'the right-click menu knows links, fields and the selection; find counts and selects',
    () async {
      await browser.open(home());
      final at = await browser.evaluate(
        '(() => { const r = document.getElementById("newtab").getBoundingClientRect(); '
        'return [r.left + 5, r.top + 5]; })()',
      );
      final xy = at! as List<Object?>;
      final link = await browser.contextAt((xy[0]! as num).toDouble(), (xy[1]! as num).toDouble());
      expect(link?.link, '${home()}popup');
      expect(link?.description, contains('<a> "New tab"'));
      expect(await browser.findText('needle'), 2);
      expect(await browser.evaluate('String(getSelection())'), 'needle');
      expect(await browser.findText('nothing here'), 0);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  ToolRunner runnerFor() => ToolRunner(
    root: tmp.path,
    shell: SessionShell(root: tmp.path, sessionTag: 't', scratchDir: '${tmp.path}/.sh'),
    gateway: GatewayClient(baseUrl: 'http://127.0.0.1:9/v1', apiKey: ''),
    sessionTag: 't',
    vision: false,
    browser: browser,
  );

  test(
    'tab switches while the Preview casts never wait on themselves',
    () async {
      final sub = browser.screencast.listen((f) => browser.ackFrame(f.session));
      addTearDown(sub.cancel);
      await browser.open(home());
      final first = browser.activeTab!;
      await browser.startScreencast();
      final sw = Stopwatch()..start();
      await browser.click(selector: '#newtab').timeout(const Duration(seconds: 8));
      await until(() => browser.tabs.value.length == 2 && browser.activeTab != first);
      expect(await browser.evaluate('document.title').timeout(const Duration(seconds: 8)), 'Sign in');
      await browser.switchTab(first).timeout(const Duration(seconds: 8));
      expect(await browser.evaluate('document.title').timeout(const Duration(seconds: 8)), 'Home');
      expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
      await browser.stopScreencast();
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'switching to a tab that shows a dialog says so at once',
    () async {
      final sub = browser.screencast.listen((f) => browser.ackFrame(f.session));
      addTearDown(sub.cancel);
      final runner = runnerFor();
      await runner.run('browser', {'action': 'open', 'url': home()});
      await browser.startScreencast();
      await browser.evaluate('window.open("/alerting", "_blank"); 1');
      await until(() => browser.tabs.value.length == 2 && browser.dialog.value != null);
      // The opener shares the pop-up's renderer: it waits too, and the switch says why instead of hanging.
      final away = await runner.run('browser', {'action': 'tab', 'index': 1});
      expect(away.text, contains('Tab 2 waits on a dialog'));
      expect(browser.dialog.value, isNull);
      final sw = Stopwatch()..start();
      final out = await runner.run('browser', {'action': 'tab', 'index': 2});
      expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
      expect(out.text, contains('Switched to tab 2'));
      expect(out.text, contains('shows an alert: "Hold on"'));
      expect(browser.dialog.value?.message, 'Hold on');
      await browser.answerDialog(accept: true).timeout(const Duration(seconds: 8));
      expect(browser.dialog.value, isNull);
      expect(await browser.evaluate('document.title').timeout(const Duration(seconds: 8)), 'Alerting');
      await browser.stopScreencast();
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'a download started inside a frame of the page is listed',
    () async {
      browser.downloadDir = '${tmp.path}/downloads';
      await browser.open('${home()}framed');
      await until(() => browser.page.value.title == 'Framed');
      await browser.evaluate(
        'new Promise(r => { const f = document.getElementById("f"); '
        'const go = () => { f.contentDocument.getElementById("dl").click(); r(1); }; '
        'f.contentDocument && f.contentDocument.getElementById("dl") ? go() : f.onload = go; })',
      );
      await until(() => browser.downloads.value.any((d) => d.state == 'completed'));
      expect(browser.downloads.value.map((d) => (d.name, d.state)), [('file.txt', 'completed')]);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test("the page's links open in a new tab only past the browser tool's guard", () {
    final home = Platform.environment['HOME'] ?? '/Users/someone';
    PageContext link(String url) =>
        (prevented: false, link: url, image: null, editable: false, selection: '', description: '<a>');
    VoidCallback? newTab(String url) =>
        pageMenuItems(browser, link(url), ask: (_) {}).firstWhere((i) => i.label == 'Open link in new tab').onSelected;
    expect(newTab('http://localhost:3000/docs'), isNotNull);
    expect(newTab(Uri.file('$home/.ssh/id_ed25519').toString()), isNull);
  });

  test('uploads: local pages and project files only, never secrets', () {
    final root = tmp.path;
    File('$root/a.txt').writeAsStringSync('a');
    File('$root/.env').writeAsStringSync('KEY=1');
    expect(uploadRefusal('http://localhost:3000/', ['a.txt'], root: root), isNull);
    expect(uploadRefusal('https://example.com/', ['a.txt'], root: root), contains('example.com is for the user'));
    expect(uploadRefusal('http://localhost:3000/', ['/etc/hosts'], root: root), contains('outside the project'));
    expect(uploadRefusal('http://localhost:3000/', ['.env'], root: root), contains('secrets'));
    expect(uploadRefusal('http://127.0.0.1:3000/', ['a.txt'], root: root), isNull);
    // A name that only starts like a loopback address is another site.
    expect(uploadRefusal('https://127.evil.example/', ['a.txt'], root: root), contains('is for the user'));
  });
}
