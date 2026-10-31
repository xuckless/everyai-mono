// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';
import 'dart:io';

/// A window on screen (macOS), front to back as CoreGraphics lists them.
typedef ScreenWindow = ({int id, int pid, String owner, String title, int width, int height});

/// The windows on screen, frontmost first; empty off macOS or on failure.
Future<List<ScreenWindow>> listWindows() async {
  if (!Platform.isMacOS) return const [];
  const script = r'''
ObjC.import("CoreGraphics");
var raw = $.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly | $.kCGWindowListExcludeDesktopElements, $.kCGNullWindowID);
var list = ObjC.deepUnwrap(ObjC.castRefToObject(raw)) || [];
JSON.stringify(list.filter(w => w.kCGWindowLayer == 0).map(w => ({
  id: w.kCGWindowNumber, pid: w.kCGWindowOwnerPID, owner: w.kCGWindowOwnerName || "", title: w.kCGWindowName || "",
  width: Math.round((w.kCGWindowBounds || {}).Width || 0), height: Math.round((w.kCGWindowBounds || {}).Height || 0)
})))''';
  try {
    final res = await Process.run('osascript', ['-l', 'JavaScript', '-e', script]);
    if (res.exitCode != 0) return const [];
    return [
      for (final w in jsonDecode(res.stdout as String) as List<Object?>)
        if (w is Map<String, Object?>)
          (
            id: (w['id'] as num).toInt(),
            pid: (w['pid'] as num).toInt(),
            owner: w['owner'] as String? ?? '',
            title: w['title'] as String? ?? '',
            width: (w['width'] as num?)?.toInt() ?? 0,
            height: (w['height'] as num?)?.toInt() ?? 0,
          ),
    ];
  } on Object {
    return const [];
  }
}

/// The executable of [pid] (its full path on macOS), or ''.
Future<String> executableOf(int pid) async {
  try {
    final res = await Process.run('ps', ['-o', 'comm=', '-p', '$pid']);
    return (res.stdout as String).trim();
  } on Object {
    return '';
  }
}

/// The windows of apps this session started: their process is one of
/// [sessionPids], or it runs from inside [root] (an app built there and
/// opened with `open`). Other apps' windows are the user's and are never
/// captured. [app] narrows by app or window name.
Future<List<ScreenWindow>> sessionWindows({required Set<int> sessionPids, required String root, String? app}) async {
  final out = <ScreenWindow>[];
  final exe = <int, String>{};
  for (final w in await listWindows()) {
    if (w.width < 40 || w.height < 40) continue;
    final own = sessionPids.contains(w.pid) || (exe[w.pid] ??= await executableOf(w.pid)).startsWith('$root/');
    if (!own) continue;
    if (app != null && app.trim().isNotEmpty) {
      final q = app.trim().toLowerCase();
      if (!w.owner.toLowerCase().contains(q) && !w.title.toLowerCase().contains(q)) continue;
    }
    out.add(w);
  }
  return out;
}

/// Captures window [id] to [path] as PNG (no shadow, no sound). Null when it
/// worked, else why not.
Future<String?> captureWindow(int id, String path) async {
  File(path).parent.createSync(recursive: true);
  final res = await Process.run('screencapture', ['-x', '-o', '-l$id', path]);
  final file = File(path);
  if (res.exitCode != 0 || !file.existsSync() || file.lengthSync() == 0) {
    return 'screencapture failed${(res.stderr as String).trim().isEmpty ? '' : ': ${(res.stderr as String).trim()}'}. '
        'EveryAI may need Screen Recording permission (System Settings → Privacy & Security → Screen Recording).';
  }
  return null;
}
