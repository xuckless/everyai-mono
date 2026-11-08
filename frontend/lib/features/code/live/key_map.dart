// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

// Keys as the DevTools protocol wants them: the physical key's DOM `code`, its Windows virtual key code (which
// Chrome uses to tell keys apart, and which pages read as `keyCode`), and the `key` value. A character's own code is
// not a key code: '.' is 46, Delete's; '-' is 45, Insert's; '(' is 40, ArrowDown's. So codes come from the physical
// key, by its USB HID usage (what Flutter's PhysicalKeyboardKey carries, also in release builds). Pure, for tests.

/// A key on a US keyboard: its DOM code, Windows virtual key, the character it types and the one with Shift (null
/// for keys that type nothing), and the `key` value of keys that type nothing.
typedef KeyInfo = ({String code, int vk, String? plain, String? shifted, String? named});

const _letters = 'abcdefghijklmnopqrstuvwxyz';

/// Keys by USB HID usage (page 7, `0x000700xx`).
final Map<int, KeyInfo> keysByUsage = {
  for (var i = 0; i < 26; i++)
    0x00070004 + i: (
      code: 'Key${_letters[i].toUpperCase()}',
      vk: 0x41 + i,
      plain: _letters[i],
      shifted: _letters[i].toUpperCase(),
      named: null,
    ),
  for (var i = 0; i < 10; i++)
    0x0007001e + i: (
      code: 'Digit${(i + 1) % 10}',
      vk: 0x30 + (i + 1) % 10,
      plain: '${(i + 1) % 10}',
      shifted: '!@#\$%^&*()'[i],
      named: null,
    ),
  0x00070028: (code: 'Enter', vk: 13, plain: null, shifted: null, named: 'Enter'),
  0x00070029: (code: 'Escape', vk: 27, plain: null, shifted: null, named: 'Escape'),
  0x0007002a: (code: 'Backspace', vk: 8, plain: null, shifted: null, named: 'Backspace'),
  0x0007002b: (code: 'Tab', vk: 9, plain: null, shifted: null, named: 'Tab'),
  0x0007002c: (code: 'Space', vk: 32, plain: ' ', shifted: ' ', named: null),
  0x0007002d: (code: 'Minus', vk: 189, plain: '-', shifted: '_', named: null),
  0x0007002e: (code: 'Equal', vk: 187, plain: '=', shifted: '+', named: null),
  0x0007002f: (code: 'BracketLeft', vk: 219, plain: '[', shifted: '{', named: null),
  0x00070030: (code: 'BracketRight', vk: 221, plain: ']', shifted: '}', named: null),
  0x00070031: (code: 'Backslash', vk: 220, plain: '\\', shifted: '|', named: null),
  0x00070033: (code: 'Semicolon', vk: 186, plain: ';', shifted: ':', named: null),
  0x00070034: (code: 'Quote', vk: 222, plain: "'", shifted: '"', named: null),
  0x00070035: (code: 'Backquote', vk: 192, plain: '`', shifted: '~', named: null),
  0x00070036: (code: 'Comma', vk: 188, plain: ',', shifted: '<', named: null),
  0x00070037: (code: 'Period', vk: 190, plain: '.', shifted: '>', named: null),
  0x00070038: (code: 'Slash', vk: 191, plain: '/', shifted: '?', named: null),
  0x00070039: (code: 'CapsLock', vk: 20, plain: null, shifted: null, named: 'CapsLock'),
  for (var i = 0; i < 12; i++)
    0x0007003a + i: (code: 'F${i + 1}', vk: 112 + i, plain: null, shifted: null, named: 'F${i + 1}'),
  0x00070049: (code: 'Insert', vk: 45, plain: null, shifted: null, named: 'Insert'),
  0x0007004a: (code: 'Home', vk: 36, plain: null, shifted: null, named: 'Home'),
  0x0007004b: (code: 'PageUp', vk: 33, plain: null, shifted: null, named: 'PageUp'),
  0x0007004c: (code: 'Delete', vk: 46, plain: null, shifted: null, named: 'Delete'),
  0x0007004d: (code: 'End', vk: 35, plain: null, shifted: null, named: 'End'),
  0x0007004e: (code: 'PageDown', vk: 34, plain: null, shifted: null, named: 'PageDown'),
  0x0007004f: (code: 'ArrowRight', vk: 39, plain: null, shifted: null, named: 'ArrowRight'),
  0x00070050: (code: 'ArrowLeft', vk: 37, plain: null, shifted: null, named: 'ArrowLeft'),
  0x00070051: (code: 'ArrowDown', vk: 40, plain: null, shifted: null, named: 'ArrowDown'),
  0x00070052: (code: 'ArrowUp', vk: 38, plain: null, shifted: null, named: 'ArrowUp'),
  0x00070054: (code: 'NumpadDivide', vk: 111, plain: '/', shifted: '/', named: null),
  0x00070055: (code: 'NumpadMultiply', vk: 106, plain: '*', shifted: '*', named: null),
  0x00070056: (code: 'NumpadSubtract', vk: 109, plain: '-', shifted: '-', named: null),
  0x00070057: (code: 'NumpadAdd', vk: 107, plain: '+', shifted: '+', named: null),
  0x00070058: (code: 'NumpadEnter', vk: 13, plain: null, shifted: null, named: 'Enter'),
  for (var i = 0; i < 9; i++)
    0x00070059 + i: (code: 'Numpad${i + 1}', vk: 97 + i, plain: '${i + 1}', shifted: '${i + 1}', named: null),
  0x00070062: (code: 'Numpad0', vk: 96, plain: '0', shifted: '0', named: null),
  0x00070063: (code: 'NumpadDecimal', vk: 110, plain: '.', shifted: '.', named: null),
  0x00070064: (code: 'IntlBackslash', vk: 226, plain: '\\', shifted: '|', named: null),
  0x000700e0: (code: 'ControlLeft', vk: 17, plain: null, shifted: null, named: 'Control'),
  0x000700e1: (code: 'ShiftLeft', vk: 16, plain: null, shifted: null, named: 'Shift'),
  0x000700e2: (code: 'AltLeft', vk: 18, plain: null, shifted: null, named: 'Alt'),
  0x000700e3: (code: 'MetaLeft', vk: 91, plain: null, shifted: null, named: 'Meta'),
  0x000700e4: (code: 'ControlRight', vk: 17, plain: null, shifted: null, named: 'Control'),
  0x000700e5: (code: 'ShiftRight', vk: 16, plain: null, shifted: null, named: 'Shift'),
  0x000700e6: (code: 'AltRight', vk: 18, plain: null, shifted: null, named: 'Alt'),
  0x000700e7: (code: 'MetaRight', vk: 92, plain: null, shifted: null, named: 'Meta'),
};

/// Keys by the `key` value of keys that type nothing ("Enter", "ArrowUp", "Shift").
final Map<String, KeyInfo> keysByName = {
  for (final k in keysByUsage.values.toList().reversed) ?k.named: k,
  'Space': keysByUsage[0x0007002c]!,
};

/// The key that types [char] on a US keyboard, and whether it takes Shift; null for characters a US keyboard has no
/// key for (é, €, emoji), which go in as text.
({KeyInfo key, bool shift})? keyForChar(String char) {
  for (final k in keysByUsage.values) {
    if (k.code.startsWith('Numpad')) continue;
    if (k.plain == char) return (key: k, shift: false);
    if (k.shifted == char) return (key: k, shift: true);
  }
  return null;
}

/// DevTools modifier bits.
const cdpAlt = 1, cdpControl = 2, cdpMeta = 4, cdpShift = 8;

/// A key press the agent asked for: "Enter", "a", "@", "Shift+Tab", "Control+a", "Meta+Shift+z". Null with an
/// unknown key or modifier.
({String key, String code, int vk, String? text, int modifiers})? parseKeyPress(String spec) {
  final parts = spec == '+' ? const ['+'] : spec.split(RegExp(r'\+(?=.)'));
  var modifiers = 0;
  for (final m in parts.take(parts.length - 1)) {
    final bit = switch (m.toLowerCase()) {
      'shift' => cdpShift,
      'control' || 'ctrl' => cdpControl,
      'alt' || 'option' => cdpAlt,
      'meta' || 'cmd' || 'command' => cdpMeta,
      _ => null,
    };
    if (bit == null) return null;
    modifiers |= bit;
  }
  final last = parts.last;
  if (keysByName[last] case final k?) {
    final text = last == 'Enter' ? '\r' : (k.plain ?? '');
    return (
      key: k.named ?? ' ',
      code: k.code,
      vk: k.vk,
      text: text.isEmpty || modifiers & (cdpControl | cdpMeta) != 0 ? null : text,
      modifiers: modifiers,
    );
  }
  if (last.runes.length != 1) return null;
  final found = keyForChar(last);
  if (found == null) {
    // A character no US key types: it goes in as text, with no key code.
    return (
      key: last,
      code: '',
      vk: 0,
      text: modifiers & (cdpControl | cdpMeta) != 0 ? null : last,
      modifiers: modifiers,
    );
  }
  final shift = found.shift || modifiers & cdpShift != 0;
  final char = shift ? (found.key.shifted ?? last) : (found.key.plain ?? last);
  return (
    key: char,
    code: found.key.code,
    vk: found.key.vk,
    // With Control or Meta it's a shortcut, not text.
    text: modifiers & (cdpControl | cdpMeta) != 0 ? null : char,
    modifiers: modifiers | (found.shift ? cdpShift : 0),
  );
}

/// The editing command Chrome runs for ⌘/Ctrl with the key [code] (headless Chrome doesn't map them from keys).
String? editingCommandFor(String code, {required bool shift}) => switch (code) {
  'KeyA' => 'selectAll',
  'KeyZ' => shift ? 'redo' : 'undo',
  'KeyY' => 'redo',
  'KeyX' => 'cut',
  'KeyC' => 'copy',
  _ => null,
};
