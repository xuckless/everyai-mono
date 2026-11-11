import 'dart:async';
import 'dart:io';

import 'package:every_ai/features/code/harness/everyai/browser_io.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tabs keep painting and reacting after a pop-up opens, a switch, a close or a dialog (real headless Chrome).
void main() {
  final chrome = HeadlessBrowser.find();
  final skip = chrome == null ? 'no Chrome installed' : null;
  late Directory tmp;
  late HeadlessBrowser browser;
  late HttpServer server;
  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('browser-alive');
    browser = HeadlessBrowser(profileDir: '${tmp.path}/profile');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    const ticking =
        '<style>@keyframes s{from{background:#f00}to{background:#00f}}#a{animation:s .3s infinite alternate;'
        'height:100px}</style><div id="a"></div><p id="n">0</p><script>let n=0;setInterval(()=>n++,50);'
        'window.tick=()=>n;</script>';
    server.listen((r) {
      final page = switch (r.uri.path) {
        '/popup' => '<title>Popup</title>$ticking<button id="done" onclick="window.close()">x</button>',
        '/alerting' => '<title>Alerting</title>$ticking<script>setTimeout(() => alert("Hold on"), 50)</script>',
        _ =>
          '<title>Home</title>$ticking<a id="pop" href="#" onclick="window.open(\'/popup\', \'p\'); return false">'
              'pop</a><a id="newtab" href="/popup" target="_blank">tab</a>',
      };
      r.response.headers.contentType = ContentType.html;
      r.response.write('<!doctype html>$page');
      r.response.close();
    });
  });
  tearDown(() async {
    await browser.close().timeout(const Duration(seconds: 10), onTimeout: () {});
    await browser.host.stop();
    await server.close(force: true);
    tmp.deleteSync(recursive: true);
  });
  String home() => 'http://localhost:${server.port}/';

  Future<void> until(bool Function() ok, {Duration within = const Duration(seconds: 6)}) async {
    final end = DateTime.now().add(within);
    while (!ok() && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  test(
    'the active tab keeps painting and reacting through pop-ups, switches, closes and dialogs',
    () async {
      var frames = 0;
      final sub = browser.screencast.listen((f) {
        frames++;
        Timer(const Duration(milliseconds: 20), () => browser.ackFrame(f.session));
      });
      addTearDown(sub.cancel);

      /// Frames keep coming and the page's own timer advances, with no help from the Preview's watchdog.
      Future<void> alive(String what) async {
        final before = frames;
        final t0 = await browser.evaluate('tick()').timeout(const Duration(seconds: 8));
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        final t1 = await browser.evaluate('tick()').timeout(const Duration(seconds: 8));
        expect((t1 as num) > (t0 as num), isTrue, reason: '$what: page timer stopped');
        expect(frames - before, greaterThan(2), reason: '$what: no frames');
        expect(await browser.evaluate('document.visibilityState'), 'visible', reason: '$what: hidden');
        expect(await browser.evaluate('document.hasFocus()'), true, reason: '$what: no focus');
      }

      await browser.open(home());
      final first = browser.activeTab!;
      await browser.startScreencast();
      await alive('first tab');

      await browser.click(selector: '#pop');
      await until(() => browser.tabs.value.length == 2 && browser.activeTab != first);
      final pop = browser.activeTab!;
      expect(pop, isNot(first));
      await alive('pop-up');

      await browser.switchTab(first);
      await alive('opener after a switch');
      await browser.switchTab(pop);
      await alive('pop-up again');

      // Quick back and forth.
      for (var i = 0; i < 4; i++) {
        unawaited(browser.switchTab(first).catchError((Object _) {}));
        unawaited(browser.switchTab(pop).catchError((Object _) {}));
      }
      await browser.switchTab(first);
      await alive('after quick switches');

      // The pop-up closes itself while it is not the active tab, then while it is.
      await browser.switchTab(pop);
      await browser.click(selector: '#done').then((_) {}, onError: (Object _) {});
      await until(() => browser.tabs.value.length == 1 && browser.activeTab == first);
      expect(browser.activeTab, first);
      await alive('after the pop-up closed');

      // A tab that shows a dialog, left and come back to.
      await browser.openTab('${home()}alerting');
      await until(() => browser.dialog.value != null);
      expect(browser.dialog.value?.message, 'Hold on');
      await browser.switchTab(first);
      await browser.switchTab(browser.tabs.value.last.id);
      expect(browser.dialog.value?.message, 'Hold on');
      await browser.answerDialog(accept: true).timeout(const Duration(seconds: 8));
      await alive('after the dialog');
      await browser.switchTab(first);
      await alive('opener of the dialog tab');
      await browser.stopScreencast();
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
