// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../../../../core/process/supervisor.dart';
import 'screen_windows.dart';

export 'screen_windows.dart';

/// The windows on screen, frontmost first; empty off macOS or on failure.
/// Windows whose app asked not to be captured (sharing state none, as
/// KeePassXC sets) are left out.
Future<List<ScreenWindow>> listWindows() async {
  if (!Platform.isMacOS) return const [];
  const script = r'''
ObjC.import("CoreGraphics");
var raw = $.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly | $.kCGWindowListExcludeDesktopElements, $.kCGNullWindowID);
var list = ObjC.deepUnwrap(ObjC.castRefToObject(raw)) || [];
JSON.stringify(list.filter(w => w.kCGWindowLayer == 0 && w.kCGWindowSharingState !== 0).map(w => ({
  id: w.kCGWindowNumber, pid: w.kCGWindowOwnerPID, owner: w.kCGWindowOwnerName || "", title: w.kCGWindowName || "",
  width: Math.round((w.kCGWindowBounds || {}).Width || 0), height: Math.round((w.kCGWindowBounds || {}).Height || 0)
})))''';
  final r = await _run('osascript', ['-l', 'JavaScript', '-e', script], 'window list');
  if (r case Finished(code: 0, :final stdout)) {
    return _windows(stdout);
  }
  debugPrint('The window list could not be read: $r');
  return const [];
}

/// A short helper run, bounded and owned by the supervisor.
Future<RunResult> _run(String exe, List<String> args, String label) => ProcessSupervisor.instance.runBounded(
  exe,
  args,
  timeout: const Duration(seconds: 10),
  owner: const ProbeOwner('screen'),
  stdoutEncoding: utf8,
  stderrEncoding: utf8,
  maxOutputBytes: 8 * 1024 * 1024,
  label: label,
);

List<ScreenWindow> _windows(String json) {
  try {
    return [
      for (final w in jsonDecode(json) as List<Object?>)
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
  } on FormatException catch (e) {
    debugPrint('The window list did not parse: $e');
    return const [];
  }
}

/// The executable of [pid] (its full path on macOS), or ''.
Future<String> executableOf(int pid) async {
  // `ps -o comm=` is the full path on macOS but only the name (15 characters) on Linux.
  if (Platform.isLinux) {
    try {
      return Link('/proc/$pid/exe').resolveSymbolicLinksSync();
    } on Object {
      return '';
    }
  }
  if (Platform.isWindows) return '';
  final r = await _run('ps', ['-o', 'comm=', '-p', '$pid'], 'ps (executable)');
  // ps exits 1 for a pid that is gone: no executable, as before.
  return r is Finished ? r.stdout.trim() : '';
}

/// Captures window [id] to [path] as PNG (no shadow, no sound). Null when it
/// worked, else why not.
Future<String?> captureWindow(int id, String path) async {
  File(path).parent.createSync(recursive: true);
  final res = await _run('screencapture', ['-x', '-o', '-l$id', path], 'screencapture');
  final file = File(path);
  final err = switch (res) {
    Finished(:final stderr) => stderr.trim(),
    TimedOut() || Cancelled() || StartFailed() || Refused() => '$res',
  };
  if (res case Finished(code: 0) when file.existsSync() && file.lengthSync() > 0) return null;
  return 'screencapture failed${err.isEmpty ? '' : ': $err'}. '
      'EveryAI may need Screen Recording permission (System Settings → Privacy & Security → Screen Recording).';
}
