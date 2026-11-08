import 'dart:io';

import 'package:every_ai/features/code/harness/everyai/browser_io.dart';
import 'package:every_ai/features/code/live/key_map.dart';
import 'package:every_ai/features/code/ui/panes/preview_pane.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the user types in the Preview reaches the page as typed: Shift, symbols, capitals (real headless Chrome).
void main() {
  final chrome = HeadlessBrowser.find();
  late Directory tmp;
  late HeadlessBrowser browser;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('browser-keys');
    browser = HeadlessBrowser(profileDir: '${tmp.path}/profile');
  });
  tearDown(() async {
    await browser.close();
    await browser.host.stop();
    tmp.deleteSync(recursive: true);
  });

  // A key as a US keyboard gives it to Flutter: the physical key, the logical (unshifted) key, the character typed.
  const keys = <String, (PhysicalKeyboardKey, LogicalKeyboardKey, bool)>{
    'H': (PhysicalKeyboardKey.keyH, LogicalKeyboardKey.keyH, true),
    'i': (PhysicalKeyboardKey.keyI, LogicalKeyboardKey.keyI, false),
    '@': (PhysicalKeyboardKey.digit2, LogicalKeyboardKey.digit2, true),
    'A': (PhysicalKeyboardKey.keyA, LogicalKeyboardKey.keyA, true),
    ' ': (PhysicalKeyboardKey.space, LogicalKeyboardKey.space, false),
    'b': (PhysicalKeyboardKey.keyB, LogicalKeyboardKey.keyB, false),
    '!': (PhysicalKeyboardKey.digit1, LogicalKeyboardKey.digit1, true),
    '.': (PhysicalKeyboardKey.period, LogicalKeyboardKey.period, false),
    '7': (PhysicalKeyboardKey.digit7, LogicalKeyboardKey.digit7, false),
    '-': (PhysicalKeyboardKey.minus, LogicalKeyboardKey.minus, false),
    "'": (PhysicalKeyboardKey.quote, LogicalKeyboardKey.quote, false),
    '(': (PhysicalKeyboardKey.digit9, LogicalKeyboardKey.digit9, true),
  };
  final downs = <PhysicalKeyboardKey, String>{};

  Future<void> send(KeyEvent e, {required bool shift}) async {
    final c = cdpKeyEvent(e, modifiers: shift ? 8 : 0, shift: shift, macOS: true, down: downs[e.physicalKey]);
    if (e is KeyUpEvent) {
      downs.remove(e.physicalKey);
    } else {
      downs[e.physicalKey] = c.key;
    }
    await browser.userKey(
      c.type,
      key: c.key,
      code: c.code,
      keyCode: c.keyCode,
      text: c.text,
      modifiers: c.modifiers,
      commands: c.commands,
    );
  }

  Future<void> typeLikeAUser(String text) async {
    const t = Duration.zero;
    for (final ch in text.split('')) {
      final (physical, logical, shifted) = keys[ch]!;
      if (shifted) {
        await send(
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.shiftLeft,
            logicalKey: LogicalKeyboardKey.shiftLeft,
            timeStamp: t,
          ),
          shift: true,
        );
      }
      await send(
        KeyDownEvent(physicalKey: physical, logicalKey: logical, character: ch, timeStamp: t),
        shift: shifted,
      );
      await send(
        KeyUpEvent(physicalKey: physical, logicalKey: logical, timeStamp: t),
        shift: shifted,
      );
      if (shifted) {
        await send(
          const KeyUpEvent(
            physicalKey: PhysicalKeyboardKey.shiftLeft,
            logicalKey: LogicalKeyboardKey.shiftLeft,
            timeStamp: t,
          ),
          shift: false,
        );
      }
    }
  }

  test(
    'capitals, @ and other shifted symbols type into the page as typed',
    () async {
      final page = File('${tmp.path}/form.html')
        ..writeAsStringSync(
          '<!doctype html><title>Form</title><input id="f" autofocus>'
          '<script>window.keys = []; f.addEventListener("keydown", e => keys.push(e.key + "|" + e.code));</script>',
        );
      await browser.open(page.uri.toString());
      await browser.evaluate('document.getElementById("f").focus()');
      await typeLikeAUser("Hi@A b!.7-'(");
      expect(await browser.evaluate('document.getElementById("f").value'), "Hi@A b!.7-'(");
      // The page's own key handlers see the real key and its physical code.
      final seen = (await browser.evaluate('keys.join(",")'))! as String;
      expect(seen, contains('@|Digit2'));
      expect(seen, contains('A|KeyA'));
      expect(seen, contains('Shift|ShiftLeft'));
      expect(seen, contains('.|Period'));
    },
    skip: chrome == null ? 'no Chrome installed' : null,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    "the agent's press types characters, capitals and symbols, and Shift+Tab moves focus back",
    () async {
      final page = File('${tmp.path}/two.html')
        ..writeAsStringSync('<!doctype html><title>Two</title><input id="a"><input id="b">');
      await browser.open(page.uri.toString());
      await browser.evaluate('document.getElementById("a").focus()');
      for (final k in ['H', 'i', '@', '.', '-']) {
        await browser.press(k);
      }
      expect(await browser.evaluate('document.getElementById("a").value'), 'Hi@.-');
      await browser.press('Tab');
      expect(await browser.evaluate('document.activeElement.id'), 'b');
      await browser.press('Shift+Tab');
      expect(await browser.evaluate('document.activeElement.id'), 'a');
      await browser.press('Meta+a');
      await browser.press('Backspace');
      expect(await browser.evaluate('document.getElementById("a").value'), '');
    },
    skip: chrome == null ? 'no Chrome installed' : null,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test('AltGr types its character off macOS; Cmd/Ctrl make shortcuts; a key-up keeps its key-down\'s key', () {
    const at = KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.keyQ,
      logicalKey: LogicalKeyboardKey.keyQ,
      character: '@',
      timeStamp: Duration.zero,
    );
    // German Windows: AltGr is Ctrl+Alt.
    final altGr = cdpKeyEvent(at, modifiers: cdpControl | cdpAlt, shift: false);
    expect((altGr.type, altGr.text, altGr.key, altGr.code), ('keyDown', '@', '@', 'KeyQ'));
    // On a Mac, Ctrl+Option is a shortcut.
    expect(cdpKeyEvent(at, modifiers: cdpControl | cdpAlt, shift: false, macOS: true).text, isNull);
    const a = KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.keyA,
      logicalKey: LogicalKeyboardKey.keyA,
      character: 'a',
      timeStamp: Duration.zero,
    );
    final selectAll = cdpKeyEvent(a, modifiers: cdpMeta, shift: false, macOS: true);
    expect((selectAll.type, selectAll.text), ('rawKeyDown', null));
    expect(selectAll.commands, ['selectAll']);
    const up = KeyUpEvent(
      physicalKey: PhysicalKeyboardKey.digit2,
      logicalKey: LogicalKeyboardKey.digit2,
      timeStamp: Duration.zero,
    );
    final released = cdpKeyEvent(up, modifiers: 0, shift: false, down: '@');
    expect((released.type, released.key, released.code, released.keyCode), ('keyUp', '@', 'Digit2', 50));
  });

  test('the agent\'s key presses: characters by their US key, Shift where it takes it, and combinations', () {
    expect(parseKeyPress('@'), (key: '@', code: 'Digit2', vk: 50, text: '@', modifiers: cdpShift));
    expect(parseKeyPress('A'), (key: 'A', code: 'KeyA', vk: 65, text: 'A', modifiers: cdpShift));
    expect(parseKeyPress('.'), (key: '.', code: 'Period', vk: 190, text: '.', modifiers: 0));
    expect(parseKeyPress('Shift+Tab'), (key: 'Tab', code: 'Tab', vk: 9, text: null, modifiers: cdpShift));
    expect(parseKeyPress('Control+a'), (key: 'a', code: 'KeyA', vk: 65, text: null, modifiers: cdpControl));
    expect(parseKeyPress('Meta+Shift+z')!.modifiers, cdpMeta | cdpShift);
    expect(parseKeyPress('Enter')!.text, '\r');
    expect(parseKeyPress('+'), (key: '+', code: 'Equal', vk: 187, text: '+', modifiers: cdpShift));
    expect(parseKeyPress('é'), (key: 'é', code: '', vk: 0, text: 'é', modifiers: 0));
    expect(parseKeyPress('Hyper+a'), isNull);
    expect(parseKeyPress('Enterr'), isNull);
  });
}
