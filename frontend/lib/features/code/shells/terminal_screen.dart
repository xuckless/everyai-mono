// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:xterm/core.dart';

/// What a terminal of [columns]×[rows] shows after [output] (a program's raw output, escape codes and all): the
/// screen a full-screen program (a TUI, an editor, a menu) drew, as text, with where the cursor is. Only the newest
/// 256 KB is replayed; a program that redraws its whole screen now and then is drawn right from there.
String terminalScreenText(String output, {required int rows, required int columns}) {
  const keep = 256 * 1024;
  final t = Terminal(maxLines: rows + 1000)..resize(columns, rows);
  t.write(output.length > keep ? output.substring(output.length - keep) : output);
  final b = t.buffer;
  final lines = [
    for (var i = 0; i < rows && b.scrollBack + i < b.height; i++) b.lines[b.scrollBack + i].getText().trimRight(),
  ];
  while (lines.isNotEmpty && lines.last.isEmpty && lines.length > b.cursorY + 1) {
    lines.removeLast();
  }
  final screen = t.isUsingAltBuffer ? 'full-screen program' : 'terminal';
  return 'Screen ($screen, $columns×$rows; cursor at row ${b.cursorY + 1}, column ${b.cursorX + 1}):\n'
      '${lines.join('\n')}';
}
