import 'dart:async';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:every_ai/features/code/live/browser_jar.dart' show SealedStore;
import 'package:every_ai/features/code/live/browser_page.dart';
import 'package:every_ai/features/code/live/webview_browser.dart';
import 'package:every_ai/features/code/live/webview_native.dart';
import 'package:every_ai/features/code/live/webview_model.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('lifecycle', () {
    final ready = Future<void>.value();
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
