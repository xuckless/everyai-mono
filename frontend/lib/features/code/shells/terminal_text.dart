// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

// Terminal output as a model reads it, and the keys it may send back.

/// [raw] terminal output as plain text: colour and cursor codes (CSI, OSC,
/// other escapes) taken out, CRLF made LF, and a line redrawn with `\r`
/// (progress bars, spinners) kept as its last state only. Backspaces erase
/// the character before them.
String cleanTerminalText(String raw) {
  if (raw.isEmpty) return raw;
  final noCodes = raw
      // OSC … BEL or ST (window titles, hyperlinks).
      .replaceAll(RegExp(r'\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)'), '')
      // CSI sequences (colours, cursor moves, erase line).
      .replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '')
      // Other two-byte escapes (charset picks, keypad modes).
      .replaceAll(RegExp(r'\x1B[@-Z\\-_()*+][0-9A-Za-z]?'), '')
      .replaceAll('\r\n', '\n');
  final out = StringBuffer();
  final lines = noCodes.split('\n');
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    // A line redrawn in place: what is left after the last carriage return, over what it overwrote.
    if (line.contains('\r')) {
      final parts = line.split('\r');
      var shown = '';
      for (final p in parts) {
        shown = p.length >= shown.length ? p : p + shown.substring(p.length);
      }
      line = shown;
    }
    if (line.contains('\b')) {
      final b = StringBuffer();
      for (final ch in line.split('')) {
        if (ch == '\b') {
          final s = b.toString();
          b
            ..clear()
            ..write(s.isEmpty ? '' : s.substring(0, s.length - 1));
        } else {
          b.write(ch);
        }
      }
      line = b.toString();
    }
    // Bell and the other C0 controls that aren't tabs.
    line = line.replaceAll(RegExp(r'[\x00-\x08\x0B-\x1F\x7F]'), '');
    out.write(line);
    if (i < lines.length - 1) out.write('\n');
  }
  return out.toString();
}

/// Whether [line] (the last line a quiet program printed) reads like it
/// waits for an answer: a y/n choice, a question, a password or a `>`/`:`
/// prompt, an interactive picker's arrow.
bool looksLikePrompt(String line) {
  final t = line.trimRight();
  if (t.isEmpty || t.length > 300) return false;
  if (RegExp(r'[\[(]\s*[yY](?:es)?\s*/\s*[nN]o?\s*[\])]').hasMatch(t)) return true;
  if (RegExp(r'\?\s*[\[(]\s*[yYnN]\s*[\])]$').hasMatch(t)) return true;
  if (RegExp(r'(password|passphrase|username|token|otp|code)\s*[:?]?\s*$', caseSensitive: false).hasMatch(t)) {
    return true;
  }
  if (RegExp(r'press (any key|enter|return)', caseSensitive: false).hasMatch(t)) return true;
  if (RegExp(r'^\s*[?❯›>]\s').hasMatch(t)) return true;
  return RegExp(r'[?:>›❯]$').hasMatch(t);
}

/// The bytes for key [name] in a terminal (`enter`, `ctrl-c`, `up`, `tab`,
/// `esc`, `backspace`, `space`, `f1`…`f12`, any `ctrl-<letter>`), or null
/// for a name it doesn't know.
String? keySequence(String name) {
  final k = name.trim().toLowerCase().replaceAll('_', '-').replaceAll('+', '-');
  const named = {
    'enter': '\r',
    'return': '\r',
    'tab': '\t',
    'shift-tab': '\x1B[Z',
    'esc': '\x1B',
    'escape': '\x1B',
    'backspace': '\x7F',
    'delete': '\x1B[3~',
    'space': ' ',
    'up': '\x1B[A',
    'down': '\x1B[B',
    'right': '\x1B[C',
    'left': '\x1B[D',
    'home': '\x1B[H',
    'end': '\x1B[F',
    'page-up': '\x1B[5~',
    'page-down': '\x1B[6~',
    'f1': '\x1BOP',
    'f2': '\x1BOQ',
    'f3': '\x1BOR',
    'f4': '\x1BOS',
    'f5': '\x1B[15~',
    'f6': '\x1B[17~',
    'f7': '\x1B[18~',
    'f8': '\x1B[19~',
    'f9': '\x1B[20~',
    'f10': '\x1B[21~',
    'f11': '\x1B[23~',
    'f12': '\x1B[24~',
  };
  if (named[k] case final s?) return s;
  final ctrl = RegExp(r'^(?:ctrl|control|c)-([a-z\[\\\]^_])$').firstMatch(k);
  if (ctrl != null) {
    final c = ctrl.group(1)!.codeUnitAt(0);
    return String.fromCharCode(c >= 0x61 && c <= 0x7A ? c - 0x60 : c - 0x40);
  }
  return null;
}

/// What the user typed into a terminal, readable in a note to the agent:
/// Enter as ⏎, controls as ^C, arrows by name, other escapes left out.
String describeTyped(String typed) {
  final b = StringBuffer();
  var rest = typed;
  const arrows = {'\x1B[A': '↑', '\x1B[B': '↓', '\x1B[C': '→', '\x1B[D': '←', '\x1BOA': '↑', '\x1BOB': '↓'};
  while (rest.isNotEmpty) {
    final arrow = arrows.keys.where(rest.startsWith).firstOrNull;
    if (arrow != null) {
      b.write(arrows[arrow]);
      rest = rest.substring(arrow.length);
      continue;
    }
    final esc = RegExp(r'^\x1B(?:\[[0-?]*[ -/]*[@-~]|O.|.)?').firstMatch(rest);
    if (esc != null) {
      b.write(esc.group(0) == '\x1B' ? '⎋' : '');
      rest = rest.substring(esc.group(0)!.length);
      continue;
    }
    final c = rest.codeUnitAt(0);
    rest = rest.substring(1);
    if (c == 0x0D || c == 0x0A) {
      b.write('⏎');
    } else if (c == 0x7F) {
      b.write('⌫');
    } else if (c == 0x09) {
      b.write('⇥');
    } else if (c < 0x20) {
      b.write('^${String.fromCharCode(c + 0x40)}');
    } else {
      b.writeCharCode(c);
    }
  }
  return b.toString();
}
