import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:window_manager/window_manager.dart';

import '../preferences.dart';

/// The window's saved size and position. Preferences `window.bounds`.
final class WindowBounds {
  const WindowBounds(this.rect, {this.maximized = false});

  final Rect rect;
  final bool maximized;

  static const key = 'window.bounds';
  static const minimum = Size(380, 520);

  String encode() =>
      jsonEncode({'x': rect.left, 'y': rect.top, 'w': rect.width, 'h': rect.height, if (maximized) 'max': true});

  /// Reads a saved value; null for anything unusable (missing, malformed, tiny or huge).
  static WindowBounds? decode(String? raw) {
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return null;
      final nums = [
        for (final k in ['x', 'y', 'w', 'h']) j[k],
      ];
      if (nums.any((n) => n is! num || !n.isFinite)) return null;
      final [x, y, w, h] = [for (final n in nums) (n as num).toDouble()];
      if (w < minimum.width || h < minimum.height || w > 16000 || h > 16000) return null;
      return WindowBounds(Rect.fromLTWH(x, y, w, h), maximized: j['max'] == true);
    } on FormatException {
      return null;
    }
  }

  /// Whether enough of the title bar lies on one of [displays] to see and drag the window. Saved bounds from a
  /// monitor that is no longer connected fail this, and the window is centered instead.
  bool visibleOn(Iterable<Rect> displays) {
    final titleBar = Rect.fromLTWH(rect.left, rect.top, rect.width, 40);
    for (final d in displays) {
      final overlap = titleBar.intersect(d);
      if (overlap.width >= 100 && overlap.height >= 20) return true;
    }
    return false;
  }
}

/// Saves the window's bounds as it moves and resizes (Windows and Linux; macOS
/// restores through AppKit's frame autosave).
final class WindowStateSaver with WindowListener {
  WindowStateSaver(this._prefs);

  final Preferences _prefs;
  Timer? _debounce;

  void start() => windowManager.addListener(this);

  void _soon() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _save);
  }

  Future<void> _save() async {
    final max = await windowManager.isMaximized();
    if (max) {
      final old = WindowBounds.decode(_prefs[WindowBounds.key]);
      if (old != null) _prefs[WindowBounds.key] = WindowBounds(old.rect, maximized: true).encode();
      return;
    }
    if (await windowManager.isMinimized() || await windowManager.isFullScreen()) return;
    _prefs[WindowBounds.key] = WindowBounds(await windowManager.getBounds()).encode();
  }

  @override
  void onWindowMoved() => _soon();
  @override
  void onWindowResized() => _soon();
  @override
  void onWindowMaximize() => _soon();
  @override
  void onWindowUnmaximize() => _soon();
}
