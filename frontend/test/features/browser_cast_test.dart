import 'dart:async';
import 'dart:io';

import 'package:every_ai/features/code/harness/everyai/browser_io.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Preview's picture keeps up with the page (real headless Chrome).
void main() {
  final chrome = HeadlessBrowser.find();
  test(
    "a session's picture keeps updating after another session of the project opens its page",
    () async {
      final tmp = Directory.systemTemp.createTempSync('cast');
      final page = File('${tmp.path}/a.html')
        ..writeAsStringSync('<h1 id="h">a</h1><button id="go" onclick="h.textContent = Date.now()">go</button>');
      final a = HeadlessBrowser(profileDir: '${tmp.path}/p');
      final other = HeadlessBrowser(profileDir: '${tmp.path}/p');
      addTearDown(() async {
        await other.close();
        await a.close();
        await a.host.stop();
        tmp.deleteSync(recursive: true);
      });
      var frames = 0;
      final sub = a.screencast.listen((f) {
        frames++;
        Timer(const Duration(milliseconds: 30), () => a.ackFrame(f.session));
      });
      addTearDown(sub.cancel);
      await a.open(page.uri.toString());
      await a.startScreencast();
      await other.open(page.uri.toString());
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final before = frames;
      for (var i = 0; i < 3; i++) {
        await a.click(selector: '#go');
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(frames - before, greaterThan(0));
    },
    skip: chrome == null ? 'no Chrome installed' : null,
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
