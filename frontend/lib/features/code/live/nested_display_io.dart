// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../core/process/child_processes.dart';

/// On Linux, each session's own headless X display (Xvfb): the apps its commands start open there, the Preview and
/// the `app` tool see and drive them, and input there never touches the user's pointer or keyboard (no consent
/// needed). Without Xvfb, or with EVERYAI_NESTED_DISPLAY=0, apps open on the user's display as usual.
abstract final class NestedDisplays {
  static final _displays = <String, _Nested>{};
  static final _starting = <String, Future<_Nested?>>{};
  static String? _xvfb;
  static bool _looked = false;

  static bool get _enabled {
    if (!Platform.isLinux || Platform.environment['EVERYAI_NESTED_DISPLAY'] == '0') return false;
    if (!_looked) {
      _looked = true;
      for (final dir in (Platform.environment['PATH'] ?? '/usr/bin:/bin').split(':')) {
        if (File('$dir/Xvfb').existsSync()) {
          _xvfb = '$dir/Xvfb';
          break;
        }
      }
    }
    return _xvfb != null;
  }

  /// What session [tag]'s commands add to their environment: its display, started on first use; {} when there's
  /// none.
  static Future<Map<String, String>> envFor(String tag) async {
    if (!_enabled) return const {};
    final d = _displays[tag] ?? await (_starting[tag] ??= _start(tag));
    if (d == null) return const {};
    return {
      'DISPLAY': ':${d.number}',
      // Toolkits that would pick Wayland go to X, so the window lands on the session's display.
      'GDK_BACKEND': 'x11',
      'QT_QPA_PLATFORM': 'xcb',
      'SDL_VIDEODRIVER': 'x11',
      'ELECTRON_OZONE_PLATFORM_HINT': 'x11',
      'WAYLAND_DISPLAY': '',
    };
  }

  /// The display of the first of [tags] that has one (":7"), or null.
  static String? displayOf(Iterable<String> tags) {
    for (final t in tags) {
      if (_displays[t] case final d?) return ':${d.number}';
    }
    return null;
  }

  static Future<_Nested?> _start(String tag) async {
    try {
      final p = await Process.start(_xvfb!, ['-displayfd', '1', '-screen', '0', '1440x900x24', '-nolisten', 'tcp']);
      ChildProcesses.track(p.pid, label: 'Xvfb ($tag)', executable: _xvfb!, exited: p.exitCode);
      unawaited(p.stderr.drain<void>());
      final line = await p.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 10));
      final n = int.tryParse(line.trim());
      if (n == null) {
        p.kill();
        return null;
      }
      return _displays[tag] = _Nested(p, n);
    } on Object {
      return null;
    } finally {
      unawaited(_starting.remove(tag));
    }
  }

  /// Ends session [tag]'s display (the session is removed).
  static void stop(String tag) => _displays.remove(tag)?.process.kill();

  /// Ends every display (the app quits).
  static void stopAll() {
    for (final d in _displays.values) {
      d.process.kill();
    }
    _displays.clear();
  }
}

final class _Nested {
  _Nested(this.process, this.number);
  final Process process;
  final int number;
}
