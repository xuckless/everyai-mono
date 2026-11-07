// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'page_snapshot.dart';

// What the `app` tool shows of a running app (Flutter, React Native), independent of how it is reached.

/// A failed app action. [fromApp] when the message quotes the app (an exception it threw, a compile error of
/// the agent's eval), so it goes in the app's untrusted block.
final class AppError implements Exception {
  const AppError(this.message, {this.fromApp = false});
  final String message;
  final bool fromApp;

  @override
  String toString() => message;
}

/// One node of an app's element list, with where it is on screen (logical pixels; null when unknown).
final class AppNode {
  const AppNode({
    required this.ref,
    required this.role,
    required this.name,
    this.value,
    this.state = const [],
    this.left,
    this.top,
    this.right,
    this.bottom,
    this.actions = const {},
    this.secret = false,
  });

  /// `s12` (Flutter semantics id) or `r3` (React Native); empty for plain text.
  final String ref;
  final String role;
  final String name;
  final String? value;
  final List<String> state;
  final double? left, top, right, bottom;

  /// What the app says the node does (Flutter: `tap`, `setText`, `scrollUp`, …).
  final Set<String> actions;

  /// A password or other obscured field: its value is never shown, and the agent never types into it.
  final bool secret;

  /// This node under another ref.
  AppNode withRef(String r) => AppNode(
    ref: r,
    role: role,
    name: name,
    value: value,
    state: state,
    left: left,
    top: top,
    right: right,
    bottom: bottom,
    actions: actions,
    secret: secret,
  );

  bool get placed => left != null && top != null && right != null && bottom != null;
  double get centreX => (left! + right!) / 2;
  double get centreY => (top! + bottom!) / 2;

  bool offscreen(double width, double height) =>
      placed && (bottom! <= 0 || top! >= height || right! <= 0 || left! >= width);

  PageElement element(double width, double height) => PageElement(
    ref: ref,
    role: role,
    // Plain text lines show only their text: its state goes with it.
    name: ref.isEmpty && state.isNotEmpty ? '$name (${state.join(', ')})' : name,
    value: secret ? null : value,
    state: [...state, if (secret) 'password'],
    offscreen: offscreen(width, height),
  );
}

/// The element list's text for an app: a header line, the nodes on screen, then the controls off screen.
String appTreeText(String header, List<AppNode> nodes, {double width = 0, double height = 0, int max = 150}) {
  final shown = nodes.take(max).toList();
  final els = [for (final n in shown) n.element(width, height)];
  final here = [
    for (final e in els)
      if (!e.offscreen) e,
  ];
  final away = [
    for (final e in els)
      if (e.offscreen && e.ref.isNotEmpty) e,
  ];
  return [
    header,
    if (els.isEmpty) '(no elements: the app may draw everything itself; use a screenshot)',
    for (final e in here) e.line,
    if (away.isNotEmpty) 'Off screen (scroll to reach):',
    for (final e in away) e.line,
    if (nodes.length > shown.length) '… ${nodes.length - shown.length} more',
  ].join('\n');
}

/// What changed between two element lists, in a line or two: what appeared and what went away (the effect of an
/// action the model should check), or null when nothing visible changed. Lines read like the element list's.
/// When most of the screen went away (a new page, a dialog over it, a long scroll) the gone items are counted, not
/// listed.
String? appTreeChange(List<AppNode> before, List<AppNode> after, {double width = 0, double height = 0}) {
  // What is off screen isn't "shown" (nor gone when it scrolls further).
  if (width > 0 && height > 0) {
    before = [
      for (final n in before)
        if (!n.offscreen(width, height)) n,
    ];
    after = [
      for (final n in after)
        if (!n.offscreen(width, height)) n,
    ];
  }
  String key(AppNode n) => [n.role, n.name, if (!n.secret) n.value ?? '', ...n.state].join('\u0001');
  String shown(AppNode n) {
    final line = n.element(double.infinity, double.infinity).line;
    return n.ref.isEmpty ? line : line.substring(n.ref.length + 3);
  }

  bool worth(AppNode n) => n.name.isNotEmpty || (n.value ?? '').isNotEmpty || n.state.isNotEmpty;
  final was = {for (final n in before) key(n)};
  final now = {for (final n in after) key(n)};
  // The same element (its ref) with another value or state: one "changed" line, not a gone and a new one.
  final beforeRefs = {
    for (final n in before)
      if (n.ref.isNotEmpty) n.ref: n,
  };
  final changedRefs = {
    for (final n in after)
      if (n.ref.isNotEmpty && beforeRefs[n.ref] != null && key(beforeRefs[n.ref]!) != key(n)) n.ref,
  };
  final changed = [
    for (final n in after)
      if (changedRefs.contains(n.ref)) '${n.ref} ${shown(n)}',
  ];
  final added = [
    for (final n in after)
      if (!was.contains(key(n)) && worth(n) && !changedRefs.contains(n.ref)) shown(n),
  ];
  final gone = [
    for (final n in before)
      if (!now.contains(key(n)) && worth(n) && !changedRefs.contains(n.ref)) shown(n),
  ];
  if (added.isEmpty && gone.isEmpty && changed.isEmpty) return null;
  String list(List<String> l) => l.length <= 8 ? l.join('; ') : '${l.take(8).join('; ')}; … ${l.length - 8} more';
  final kept = before.where((n) => now.contains(key(n))).length;
  final mostGone = gone.length > 6 && gone.length > kept;
  return [
    if (changed.isNotEmpty) 'Changed: ${list(changed)}',
    if (added.isNotEmpty) 'Now shown: ${list(added)}',
    if (gone.isNotEmpty)
      mostGone
          ? 'No longer shown: ${gone.length} items (a new page or a dialog over it, or scrolled away)'
          : 'No longer shown: ${list(gone)}',
  ].join('\n');
}

/// An error from the app (a Dart exception with its stack) cut to its first lines: the stack is noise for the model.
String shortError(String message, {int lines = 6}) {
  final all = message.split('\n');
  if (all.length <= lines) return message;
  return '${all.take(lines).join('\n')}\n… (${all.length - lines} more lines of stack)';
}

/// [s] as a Dart string literal (for expressions evaluated in the app).
String dartString(String s) {
  final b = StringBuffer("'");
  for (final r in s.runes) {
    switch (r) {
      case 0x5c:
        b.write(r'\\');
      case 0x27:
        b.write(r"\'");
      case 0x24:
        b.write(r'\$');
      case 0x0a:
        b.write(r'\n');
      case 0x0d:
        b.write(r'\r');
      case 0x09:
        b.write(r'\t');
      default:
        if (r < 0x20) {
          b.write('\\u{${r.toRadixString(16)}}');
        } else {
          b.writeCharCode(r);
        }
    }
  }
  b.write("'");
  return b.toString();
}

/// Dart source as one line (the VM's expression evaluator reads only the first): line comments dropped, lines
/// joined with spaces.
String oneLineDart(String source) => source
    .split('\n')
    .map((l) {
      // A `//` outside a string literal starts a comment: good enough for the agent's short expressions.
      final i = _commentStart(l);
      return (i < 0 ? l : l.substring(0, i)).trim();
    })
    .where((l) => l.isNotEmpty)
    .join(' ');

int _commentStart(String l) {
  String? quote;
  for (var i = 0; i < l.length - 1; i++) {
    final c = l[i];
    if (quote != null) {
      if (c == r'\') {
        i++;
      } else if (c == quote) {
        quote = null;
      }
    } else if (c == '"' || c == "'") {
      quote = c;
    } else if (c == '/' && l[i + 1] == '/') {
      return i;
    }
  }
  return -1;
}
