import 'dart:async';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:every_ai/features/code/live/browser_jar.dart' show SealedStore;
import 'package:every_ai/features/code/live/browser_page.dart';
import 'package:every_ai/features/code/live/webview_browser.dart';
import 'package:every_ai/features/code/live/webview_native.dart';
import 'package:every_ai/features/code/live/key_map.dart';
import 'package:every_ai/features/code/live/webview_model.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('backendFor', () {
    test('the OS webview on macOS and Windows, Chrome elsewhere', () {
      expect(backendFor(TargetPlatform.macOS), BrowserBackend.osWebview);
      expect(backendFor(TargetPlatform.windows), BrowserBackend.osWebview);
      expect(backendFor(TargetPlatform.linux), BrowserBackend.chromeStream);
      expect(backendFor(TargetPlatform.android), BrowserBackend.chromeStream);
    });

    test('EVERYAI_BROWSER=chrome goes back to Chrome; webview cannot run where there is none', () {
      expect(backendFor(TargetPlatform.macOS, choice: 'chrome'), BrowserBackend.chromeStream);
      expect(backendFor(TargetPlatform.macOS, choice: ' Chrome '), BrowserBackend.chromeStream);
      expect(backendFor(TargetPlatform.macOS, choice: 'webview'), BrowserBackend.osWebview);
      expect(backendFor(TargetPlatform.linux, choice: 'webview'), BrowserBackend.chromeStream);
      expect(backendFor(TargetPlatform.macOS, choice: 'nonsense'), BrowserBackend.osWebview);
    });

    test('no platform views (flutter test): Chrome', () {
      expect(backendFor(TargetPlatform.macOS, platformViews: false), BrowserBackend.chromeStream);
      expect(backendFor(TargetPlatform.macOS, choice: 'webview', platformViews: false), BrowserBackend.chromeStream);
    });
  });

  group('lifecycle', () {
    final ready = Future<void>.value();
    test('the browser moves only along its edges', () {
      const notCreated = WebviewNotCreated(), closed = WebviewClosed();
      final starting = WebviewStarting(1, ready);
      const headless = WebviewRunning(1, shown: false), shown = WebviewRunning(1, shown: true);
      final closing = WebviewClosing(ready);
      expect(webviewEdge(notCreated, starting), isTrue);
      expect(webviewEdge(starting, headless), isTrue);
      expect(webviewEdge(headless, shown), isTrue);
      expect(webviewEdge(shown, headless), isTrue);
      expect(webviewEdge(shown, closing), isTrue);
      expect(webviewEdge(starting, closing), isTrue);
      expect(webviewEdge(closing, closed), isTrue);
      expect(webviewEdge(closed, starting), isTrue);
      expect(webviewEdge(notCreated, headless), isFalse);
      expect(webviewEdge(closed, headless), isFalse);
      expect(webviewEdge(closing, headless), isFalse);
      expect(webviewEdge(headless, closed), isFalse);
    });

    test('a tab is shown only from offscreen, and parks before it shows again', () {
      expect(TabLife.starting.canMoveTo(TabLife.headless), isTrue);
      expect(TabLife.headless.canMoveTo(TabLife.shown), isTrue);
      expect(TabLife.shown.canMoveTo(TabLife.parking), isTrue);
      expect(TabLife.parking.canMoveTo(TabLife.shown), isFalse);
      expect(TabLife.parking.canMoveTo(TabLife.parked), isTrue);
      expect(TabLife.parked.canMoveTo(TabLife.shown), isTrue);
      expect(TabLife.closed.canMoveTo(TabLife.closed), isFalse);
      for (final l in TabLife.values.where((l) => l != TabLife.closed)) {
        expect(l.canMoveTo(TabLife.closed), isTrue, reason: l.name);
      }
      expect(TabLife.parking.showable, isFalse);
      expect(TabLife.parked.showable, isTrue);
      // A park that failed is its own state: shown from there, parked on a later try, never counted as parked.
      expect(TabLife.parking.canMoveTo(TabLife.unparked), isTrue);
      expect(TabLife.unparked.canMoveTo(TabLife.shown), isTrue);
      expect(TabLife.unparked.canMoveTo(TabLife.parked), isTrue);
      expect(TabLife.headless.canMoveTo(TabLife.unparked), isFalse);
      expect(TabLife.unparked.showable, isTrue);
    });

    test('a close while starting: starting → closing → closed, and the start is no longer current', () {
      final starting = WebviewStarting(3, ready);
      expect(webviewStartCurrent(starting, 3), isTrue);
      expect(webviewStartCurrent(const WebviewRunning(3, shown: false), 3), isTrue);
      // The close moves on at once; the start's native calls come back later and find it isn't theirs.
      final closing = WebviewClosing(ready);
      expect(webviewEdge(starting, closing), isTrue);
      expect(webviewStartCurrent(closing, 3), isFalse);
      expect(webviewEdge(closing, const WebviewClosed()), isTrue);
      expect(webviewStartCurrent(const WebviewClosed(), 3), isFalse);
      // A later start is another generation: the old one's late answer isn't current under it either.
      expect(webviewStartCurrent(WebviewStarting(4, ready), 3), isFalse);
      // And the late start can't take the browser to running from closed.
      expect(webviewEdge(const WebviewClosed(), const WebviewRunning(3, shown: false)), isFalse);
    });

    test('the jar: read once, written only once read, never after the session was removed', () {
      final reading = JarReading(Future<void>.value());
      final writing = JarWriting(Future<void>.value());
      expect(jarEdge(const JarUnread(), reading), isTrue);
      expect(jarEdge(reading, const JarReady()), isTrue);
      expect(jarEdge(reading, const JarUnreadable()), isTrue);
      expect(jarEdge(reading, const JarUnread()), isTrue);
      expect(jarEdge(const JarReady(), writing), isTrue);
      expect(jarEdge(writing, writing), isTrue);
      expect(jarEdge(writing, const JarReady()), isTrue);
      expect(jarEdge(const JarUnreadable(), writing), isFalse);
      expect(jarEdge(const JarUnread(), writing), isFalse);
      for (final l in [const JarUnread(), reading, const JarReady(), writing, const JarUnreadable()]) {
        expect(jarEdge(l, const JarForgotten()), isTrue);
      }
      expect(jarEdge(const JarForgotten(), writing), isFalse);
      expect(jarEdge(const JarForgotten(), const JarForgotten()), isFalse);
      expect(
        [
          for (final l in [const JarReady(), writing]) jarWritable(l),
        ],
        [true, true],
      );
      expect([
        for (final l in [const JarUnread(), reading, const JarUnreadable(), const JarForgotten()]) jarWritable(l),
      ], everyElement(isFalse));
    });

    test('a new-tab request is answered by the window opened for its address, not by any pop-up', () {
      final pending = ['https://a.com', 'https://b.com/x'];
      expect(matchOpenRequest(pending, 'https://b.com/x'), 1);
      expect(matchOpenRequest(pending, 'https://a.com/'), 0);
      expect(matchOpenRequest(pending, 'https://ads.example/pop'), isNull);
      expect(matchOpenRequest(const [], 'https://a.com'), isNull);
    });
  });

  group('cookies', () {
    test('a jar cookie survives the round trip through the native store', () {
      final now = DateTime.utc(2026, 11, 11);
      final jar = <String, Object?>{
        'name': 'sid',
        'value': 'abc',
        'domain': '.example.com',
        'path': '/app',
        'expires': now.millisecondsSinceEpoch / 1000 + 3600,
        'httpOnly': true,
        'secure': true,
        'session': false,
        'sameSite': 'Lax',
      };
      final n = nativeCookieOf(jar, now: now)!;
      expect(n.httpOnly, isTrue);
      expect(n.sameSite, 'Lax');
      final back = jarCookieOf(nativeCookieFromMap(nativeCookieToMap(n))!);
      for (final k in ['name', 'value', 'domain', 'path', 'expires', 'httpOnly', 'secure', 'session', 'sameSite']) {
        expect(back[k], jar[k], reason: k);
      }
    });

    test('session cookies have no expiry; expired ones are dropped', () {
      final now = DateTime.utc(2026, 11, 11);
      final s = nativeCookieOf({'name': 'a', 'value': '1', 'domain': 'x.dev', 'session': true}, now: now)!;
      expect(s.expiresMs, isNull);
      expect(jarCookieOf(s)['session'], isTrue);
      expect(jarCookieOf(s)['expires'], -1);
      expect(nativeCookieOf({'name': 'a', 'domain': 'x.dev', 'expires': 1000}, now: now), isNull);
      expect(nativeCookieOf({'name': '', 'domain': 'x.dev'}), isNull);
    });

    test('a download carries the cookies a browser would send', () {
      const c = (
        name: 'n',
        value: 'v',
        domain: '.example.com',
        path: '/a',
        expiresMs: null,
        secure: true,
        httpOnly: false,
        sameSite: null,
      );
      expect(cookieMatches(c, Uri.parse('https://www.example.com/a/b')), isTrue);
      expect(cookieMatches(c, Uri.parse('https://example.com/a')), isTrue);
      expect(cookieMatches(c, Uri.parse('http://example.com/a')), isFalse);
      expect(cookieMatches(c, Uri.parse('https://example.com/ab')), isFalse);
      expect(cookieMatches(c, Uri.parse('https://badexample.com/a')), isFalse);
    });
  });

  test('what a key press does by default', () {
    KeyDefault of(String spec) => keyDefaultOf(parseKeyPress(spec)!);
    expect(of('Enter'), KeyDefault.enter);
    expect(of('Tab'), KeyDefault.focusNext);
    expect(of('Shift+Tab'), KeyDefault.focusPrevious);
    expect(of('Backspace'), KeyDefault.deleteBackward);
    expect(of('Delete'), KeyDefault.deleteForward);
    expect(of('Space'), KeyDefault.space);
    expect(of('a'), KeyDefault.insertText);
    expect(of('@'), KeyDefault.insertText);
    expect(of('Control+a'), KeyDefault.selectAll);
    expect(of('Meta+a'), KeyDefault.selectAll);
    expect(of('Meta+z'), KeyDefault.undo);
    expect(of('Meta+Shift+z'), KeyDefault.redo);
    expect(of('Control+x'), KeyDefault.cut);
    expect(of('Control+q'), KeyDefault.none);
    expect(of('ArrowDown'), KeyDefault.arrowDown);
    expect(of('PageUp'), KeyDefault.pageUp);
    expect(of('End'), KeyDefault.end);
    expect(of('Escape'), KeyDefault.none);
  });

  test('a Safari user agent with no embedded-view marker', () {
    final ua = safariUserAgent(27);
    expect(ua, contains('Version/27.0 Safari/605.1.15'));
    expect(safariUserAgent(15), contains('Version/18.0'));
    expect(ua.toLowerCase(), isNot(contains('wv')));
  });

  test('pngSize reads the header', () {
    final header = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52];
    expect(pngSize([...header, 0, 0, 5, 0, 0, 0, 3, 32]), (width: 1280, height: 800));
    expect(pngSize([1, 2, 3]), isNull);
  });

  group('the browser object', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('webview'));
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tmp.deleteSync(recursive: true);
    });

    test('a close while the start waits ends it closed; the late start makes nothing', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final store = Completer<SealedStore>();
      final b = WebviewBrowser(
        native: _FakeNative(),
        jarHome: (store: () => store.future, name: 'jar-x'),
        tempRoot: tmp.path,
      );
      final opening = b.open('about:blank');
      await Future<void>.delayed(Duration.zero);
      expect(b.life.value, isA<WebviewStarting>());
      await b.close();
      expect(b.life.value, isA<WebviewClosed>());
      // The start's jar read comes back after the close.
      store.complete(SealedStore('${tmp.path}/s', () async => SecretKey(List.filled(32, 1))));
      await expectLater(opening, throwsA(isA<BrowserError>()));
      expect(b.life.value, isA<WebviewClosed>());
      expect(b.tabs.value, isEmpty);
      expect(b.refusedMoves, isEmpty);
    });

    test('left-over WebView2 folders go at start; a running owner keeps its own', () async {
      Directory folder(String name, {int? owner}) {
        final d = Directory('${tmp.path}/$name')..createSync();
        if (owner != null) File('${d.path}/.everyai-owner').writeAsStringSync('$owner');
        return d;
      }

      final dead = folder('session-a', owner: 111), live = folder('session-b', owner: 222);
      final fresh = folder('session-c'), other = folder('keep-me', owner: 111);
      final gone = await sweepWebviewFolders(root: tmp.path, alive: (p) => p == 222);
      expect(gone, 1);
      expect([dead, live, fresh, other].map((d) => d.existsSync()), [false, true, true, true]);
      // An unclaimed folder past the grace counts as left over.
      expect(await sweepWebviewFolders(root: tmp.path, alive: (p) => p == 222, grace: Duration.zero), 1);
      expect(fresh.existsSync(), isFalse);
    });
  });
}

final class _FakeNative implements WebviewNative {
  @override
  Stream<WebviewNativeEvent> get events => const Stream.empty();
  @override
  Future<bool> bind(String token, {String? viewId}) async => true;
  @override
  Future<void> release(String token) async {}
  @override
  Future<List<NativeCookie>> cookies(String token, {Iterable<Uri> urls = const []}) async => const [];
  @override
  Future<void> setCookies(String token, List<NativeCookie> cookies) async {}
  @override
  Future<void> deleteCookies(String token, List<NativeCookie> cookies) async {}
  @override
  Future<void> clearData(String token) async {}
  @override
  Future<bool> park(String token, int width, int height) async => true;
  @override
  Future<void> unfocus(String token) async {}
  @override
  Future<void> setLocked(String token, bool locked) async {}
  @override
  Future<void> lendWindow(bool on) async {}
  @override
  Future<void> setShown(String token, bool shown) async {}
}
