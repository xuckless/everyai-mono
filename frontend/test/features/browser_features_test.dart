import 'dart:io';

import 'package:every_ai/features/code/harness/everyai/browser_io.dart';
import 'package:every_ai/features/code/harness/everyai/screen_tools_io.dart';
import 'package:every_ai/features/code/ui/panes/browser_overlays.dart';
import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:flutter_test/flutter_test.dart';

/// The right-click menu and upload guards (no Chrome is started).
void main() {
  late Directory tmp;
  late HeadlessBrowser browser;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('browser-features');
    browser = HeadlessBrowser(profileDir: '${tmp.path}/profile');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

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
