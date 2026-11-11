import 'dart:io';

import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/harness/everyai/browser_io.dart';
import 'package:every_ai/features/code/ui/panes/browser_overlays.dart';
import 'package:every_ai/features/code/ui/panes/preview_pane.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

/// The Preview browser's dialogs, right-click menu and find, on a real headless Chrome.
void main() {
  final chrome = HeadlessBrowser.find();
  late Directory tmp;
  late HeadlessBrowser browser;
  String? clipboard;

  Future<void> start(WidgetTester tester, String html) async {
    tmp = Directory.systemTemp.createTempSync('preview-ui');
    browser = HeadlessBrowser(profileDir: '${tmp.path}/p');
    final page = File('${tmp.path}/a.html')..writeAsStringSync('<!doctype html><body style="margin:0">$html');
    await tester.runAsync(() => browser.open(page.uri.toString()));
    addTearDown(() async {
      await tester.runAsync(() async {
        await browser.close();
        await browser.host.stop();
      });
      tmp.deleteSync(recursive: true);
    });
    clipboard = null;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      switch (call.method) {
        case 'Clipboard.setData':
          clipboard = (call.arguments as Map)['text'] as String?;
          return null;
        case 'Clipboard.getData':
          return {'text': clipboard};
        case 'Clipboard.hasStrings':
          return {'value': clipboard != null};
      }
      return null;
    });
  }

  Widget host(Widget child) => m.MaterialApp(
    builder: (context, c) =>
        EveryThemeScope(theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light), child: c!),
    home: m.Material(child: SizedBox(width: 1280, height: 800, child: child)),
  );

  Future<void> settle(WidgetTester tester, [int ms = 400]) async {
    // Timers started in the test's fake time first, then real time for Chrome's answers.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
    // An answer can take a few hops (each a microtask) before its setState: two frames.
    await tester.pump();
    await tester.pump();
  }

  testWidgets(
    'a prompt shows over the page; pasted text answers it',
    (tester) async {
      await start(tester, '<button id="b" onclick="window.answer = prompt(\'Your name?\', \'\')">Ask</button>');
      await tester.pumpWidget(
        host(
          ValueListenableBuilder<PageDialog?>(
            valueListenable: browser.dialog,
            builder: (context, d, _) =>
                d == null ? const SizedBox() : PageDialogPanel(key: ValueKey(d), browser: browser, dialog: d),
          ),
        ),
      );
      await tester.runAsync(() => browser.click(selector: '#b').then((_) {}, onError: (Object _) {}));
      await settle(tester);
      expect(find.text('Your name?'), findsOneWidget);
      // Answering the page's dialog is the user's to do once they hold the view.
      browser.control.take();
      await tester.pump();
      clipboard = 'Ada Lovelace';
      await tester.tap(find.byType(EditableText));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft, platform: 'macos');
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV, platform: 'macos');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft, platform: 'macos');
      await settle(tester, 100);
      await tester.tap(find.text('OK'));
      await settle(tester);
      expect(await tester.runAsync(() => browser.evaluate('window.answer')), 'Ada Lovelace');
      expect(browser.dialog.value, isNull);
    },
    skip: chrome == null,
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets('a right-click on a link offers to copy it or open it in a new tab', (tester) async {
    await start(
      tester,
      '<a id="l" href="https://example.com/x" style="display:block;width:300px;height:60px">A link</a>',
    );
    browser.control.take();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    String? asked;
    await tester.pumpWidget(
      host(
        PreviewPageView(
          image: null,
          browser: browser,
          focus: focus,
          device: null,
          ghost: null,
          onAsk: (t) => asked = t,
        ),
      ),
    );
    await tester.pump();
    // The page is scaled into the view: a point near its top-left corner is inside the link.
    final topLeft = tester.getTopLeft(
      find.descendant(of: find.byType(PreviewPageView), matching: find.byType(MouseRegion)).first,
    );
    await tester.tapAt(topLeft + const Offset(15, 15), kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await settle(tester, 600);
    expect(find.text('Copy link address'), findsOneWidget);
    expect(find.text('Open link in new tab'), findsOneWidget);
    await tester.tap(find.text('Copy link address'));
    await tester.pump();
    expect(clipboard, 'https://example.com/x');
    expect(find.text('Copy link address'), findsNothing);
    await tester.tapAt(topLeft + const Offset(15, 15), kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await settle(tester, 600);
    await tester.tap(find.text('Ask the agent about this'));
    await tester.pump();
    expect(asked, contains('<a> "A link"'));
  }, skip: chrome == null);

  testWidgets('find counts the matches', (tester) async {
    await start(tester, '<p>one needle, two needle, three needle</p>');
    await tester.pumpWidget(host(BrowserFindBar(browser: browser, onClose: () {})));
    await tester.pump();
    await tester.enterText(find.byType(EditableText), 'needle');
    await settle(tester);
    expect(find.text('3 matches'), findsOneWidget);
  }, skip: chrome == null);
}
