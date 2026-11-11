import 'dart:io';

import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/harness/everyai/browser_io.dart';
import 'package:every_ai/features/code/ui/panes/preview_pane.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

/// ⌘C and ⌘V in the Preview reach the page through Flutter's own focus and keyboard (real headless Chrome).
void main() {
  final chrome = HeadlessBrowser.find();

  testWidgets('click the page, then ⌘C copies its selection and ⌘V pastes into its field', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('clip');
    final browser = HeadlessBrowser(profileDir: '${tmp.path}/p');
    final page = File('${tmp.path}/a.html')
      ..writeAsStringSync(
        '<!doctype html><body style="margin:0"><p id="p">Copy me</p>'
        '<input id="i" style="position:absolute;left:0;top:200px;width:400px;height:40px"></body>',
      );
    await tester.runAsync(() => browser.open(page.uri.toString()));
    addTearDown(() async {
      await tester.runAsync(() async {
        await browser.close();
        await browser.host.stop();
      });
      tmp.deleteSync(recursive: true);
    });
    String? clipboard = 'pasted text';
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      switch (call.method) {
        case 'Clipboard.setData':
          clipboard = (call.arguments as Map)['text'] as String?;
          return null;
        case 'Clipboard.getData':
          return {'text': clipboard};
      }
      return null;
    });
    browser.control.take();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      m.MaterialApp(
        builder: (context, child) =>
            EveryThemeScope(theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light), child: child!),
        home: SizedBox(
          width: 1280,
          height: 800,
          child: PreviewPageView(image: null, browser: browser, focus: focus, device: null, ghost: null),
        ),
      ),
    );
    await tester.pump();

    Future<void> settle() => tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
    Future<Object?> js(String s) async => tester.runAsync<Object?>(() => browser.evaluate(s));

    // Copy: the page's selection.
    await tester.tap(find.byType(PreviewPageView), warnIfMissed: false);
    await settle();
    expect(focus.hasPrimaryFocus, isTrue, reason: 'a click on the page gives it the keyboard');
    await js('getSelection().selectAllChildren(document.getElementById("p"))');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft, platform: 'macos');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC, platform: 'macos');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft, platform: 'macos');
    await settle();
    await tester.pump();
    expect(clipboard, 'Copy me');

    // Paste: into the field the user clicked.
    clipboard = 'pasted text';
    await js('document.getElementById("i").focus()');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft, platform: 'macos');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV, platform: 'macos');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft, platform: 'macos');
    await settle();
    await tester.pump();
    expect(await js('document.getElementById("i").value'), 'pasted text');
  }, skip: chrome == null);
}
