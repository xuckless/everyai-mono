// The macOS menu bar is mounted once, at the app root, and nothing else builds one: a second PlatformMenuBar that
// mounts before the first is disposed asserts in platform_menu_bar.dart (the crash this guards against).

import 'dart:io';

import 'package:every_ai/app/app_menu.dart';
import 'package:flutter_test/flutter_test.dart';

/// [body] on [platform]; the override is reset inside the test (Flutter checks it before tear-downs run).
/// Lets the holder's microtask notify, then rebuilds.
void main() {
  tearDown(AppMenuActions.instance.reset);

  test('only the app root builds a PlatformMenuBar', () {
    final builders = [
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>())
        if (f.path.endsWith('.dart') && f.readAsStringSync().contains('PlatformMenuBar(')) f.path,
    ];
    expect(builders, [endsWith('app/app_menu.dart')], reason: 'mount the menu bar once (see app_menu.dart)');
    expect(File('lib/app/app.dart').readAsStringSync(), contains('return AppMenuBar('));
  });
}
