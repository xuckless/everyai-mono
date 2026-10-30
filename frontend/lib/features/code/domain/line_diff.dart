import 'package:flutter/foundation.dart';

enum DiffKind { same, added, removed, gap }

@immutable
final class DiffLine {
  const DiffLine(this.kind, this.text, {this.oldNo, this.newNo});
  final DiffKind kind;
  final String text;
  final int? oldNo;
  final int? newNo;
}

/// A line diff of [before] → [after] (LCS), trimmed to [context] lines
/// around each change; skipped stretches become one [DiffKind.gap] line.
List<DiffLine> lineDiff(String before, String after, {int context = 3}) {
  final a = before.isEmpty ? const <String>[] : before.split('\n');
  final b = after.isEmpty ? const <String>[] : after.split('\n');
  // Strip the common head and tail so the table stays small.
  var head = 0;
  while (head < a.length && head < b.length && a[head] == b[head]) {
    head++;
  }
  var tail = 0;
  while (tail < a.length - head && tail < b.length - head && a[a.length - 1 - tail] == b[b.length - 1 - tail]) {
    tail++;
  }
  final ma = a.sublist(head, a.length - tail), mb = b.sublist(head, b.length - tail);
  final n = ma.length, m = mb.length;
  final lines = <DiffLine>[for (var i = 0; i < head; i++) DiffLine(DiffKind.same, a[i], oldNo: i + 1, newNo: i + 1)];

  if (n * m > 4000000) {
    // Too big to align: show it as a replacement.
    for (var i = 0; i < n; i++) {
      lines.add(DiffLine(DiffKind.removed, ma[i], oldNo: head + i + 1));
    }
    for (var j = 0; j < m; j++) {
      lines.add(DiffLine(DiffKind.added, mb[j], newNo: head + j + 1));
    }
  } else {
    final lcs = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
    for (var i = n - 1; i >= 0; i--) {
      for (var j = m - 1; j >= 0; j--) {
        lcs[i][j] = ma[i] == mb[j]
            ? lcs[i + 1][j + 1] + 1
            : (lcs[i + 1][j] >= lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
      }
    }
    var i = 0, j = 0;
    while (i < n || j < m) {
      if (i < n && j < m && ma[i] == mb[j]) {
        lines.add(DiffLine(DiffKind.same, ma[i], oldNo: head + i + 1, newNo: head + j + 1));
        i++;
        j++;
      } else if (j < m && (i == n || lcs[i][j + 1] >= lcs[i + 1][j])) {
        lines.add(DiffLine(DiffKind.added, mb[j], newNo: head + j + 1));
        j++;
      } else {
        lines.add(DiffLine(DiffKind.removed, ma[i], oldNo: head + i + 1));
        i++;
      }
    }
  }
  for (var k = 0; k < tail; k++) {
    final oi = a.length - tail + k, ni = b.length - tail + k;
    lines.add(DiffLine(DiffKind.same, a[oi], oldNo: oi + 1, newNo: ni + 1));
  }
  return _fold(lines, context);
}

List<DiffLine> _fold(List<DiffLine> lines, int context) {
  final keep = List<bool>.filled(lines.length, false);
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].kind == DiffKind.same) continue;
    for (var k = (i - context).clamp(0, lines.length); k <= (i + context).clamp(0, lines.length - 1); k++) {
      keep[k] = true;
    }
  }
  final out = <DiffLine>[];
  var skipped = 0;
  for (var i = 0; i < lines.length; i++) {
    if (keep[i]) {
      if (skipped > 0) out.add(DiffLine(DiffKind.gap, '$skipped unchanged ${skipped == 1 ? 'line' : 'lines'}'));
      skipped = 0;
      out.add(lines[i]);
    } else {
      skipped++;
    }
  }
  if (skipped > 0 && out.isNotEmpty) out.add(DiffLine(DiffKind.gap, '$skipped unchanged lines'));
  return out;
}

/// (+added, −removed) for a diff.
({int added, int removed}) diffStats(List<DiffLine> lines) => (
  added: lines.where((l) => l.kind == DiffKind.added).length,
  removed: lines.where((l) => l.kind == DiffKind.removed).length,
);
