// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../../../core/process/supervisor.dart';

/// Where one session's display is:
///
/// ```text
///   (none) ──envFor──▶ Starting ──number read──▶ Up(child, n) ──stop──▶ Stopping ──outcome──▶ (none)
///                        │ timeout / no number / exit                         │ not ended
///                        ▼ (what it started is stopped, verified)             ▼
///                      (none)                                    NotClosed(outcome) ──stop──▶ Stopping
///   Up ──Xvfb exited by itself──▶ (none)
/// ```
sealed class _Display {
  const _Display();
}

final class _Starting extends _Display {
  const _Starting(this.done);
  final Future<_Up?> done;
}

final class _Up extends _Display {
  const _Up(this.child, this.number);
  final SupervisedProcess child;
  final int number;
}

final class _Stopping extends _Display {
  const _Stopping(this.done);
  final Future<KillOutcome> done;
}

final class _NotClosed extends _Display {
  const _NotClosed(this.child, this.outcome);
  final SupervisedProcess child;
  final KillOutcome outcome;
}

/// On Linux, each session's own headless X display (Xvfb): the apps its commands start open there, the Preview and
/// the `app` tool see and drive them, and input there never touches the user's pointer or keyboard (no consent
/// needed). Without Xvfb, or with EVERYAI_NESTED_DISPLAY=0, apps open on the user's display as usual. Each Xvfb is a
/// child of the process supervisor owned by its session, so it ends with the session and the app.
abstract final class NestedDisplays {
  static final _displays = <String, _Display>{};
  static String? _xvfb;
  static bool _looked = false;

  /// The Xvfb program and how long it may take to say its display (tests use a stand-in).
  @visibleForTesting
  static String? program;
  @visibleForTesting
  static Duration startTimeout = const Duration(seconds: 10);

  static bool get _enabled {
    if (program != null) return true;
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
    final up = switch (_displays[tag]) {
      final _Up d => d,
      _Starting(:final done) => await done,
      _Stopping() || _NotClosed() => null,
      null => await _start(tag),
    };
    if (up == null) return const {};
    return {
      'DISPLAY': ':${up.number}',
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
      if (_displays[t] case _Up(:final number)) return ':$number';
    }
    return null;
  }

  static Future<_Up?> _start(String tag) {
    final done = _launch(tag);
    _displays[tag] = _Starting(done);
    return done;
  }

  static Future<_Up?> _launch(String tag) async {
    final exe = program ?? _xvfb!;
    final SupervisedProcess p;
    try {
      p = await ProcessSupervisor.instance.spawn(
        SpawnSpec(
          owner: SessionOwner(tag),
          kind: ProcessKind.display,
          exe: exe,
          args: const ['-displayfd', '1', '-screen', '0', '1440x900x24', '-nolisten', 'tcp'],
          label: 'Xvfb ($tag)',
        ),
      );
    } on Object catch (e) {
      debugPrint('Xvfb for $tag did not start: $e');
      if (_displays[tag] is _Starting) _displays.remove(tag);
      return null;
    }
    unawaited(p.stderr.drain<void>().catchError((Object e) => debugPrint('Xvfb ($tag) stderr: $e')));
    final lines = StreamIterator(p.stdout.transform(utf8.decoder).transform(const LineSplitter()));
    int? n;
    var why = 'it said no display number';
    try {
      n = await lines.moveNext().timeout(startTimeout) ? int.tryParse(lines.current.trim()) : null;
    } on TimeoutException {
      why = 'it said no display number within ${startTimeout.inSeconds} s';
    }
    if (n == null || _displays[tag] is! _Starting) {
      // What it started must not run on: stopped and checked.
      final outcome = await p.stop();
      await lines.cancel();
      if (_displays[tag] is _Starting) _displays.remove(tag);
      if (outcome is! Ended) {
        debugPrint('NOT CLOSED: Xvfb ($tag) after a failed start ($why): $outcome');
        _displays[tag] = _NotClosed(p, outcome);
      } else if (n == null) {
        debugPrint('Xvfb for $tag did not start: $why.');
      }
      return null;
    }
    // Drained: Xvfb prints nothing more, but a full pipe would stall it.
    unawaited(_drain(lines, tag));
    final up = _Up(p, n);
    _displays[tag] = up;
    // A display that dies by itself is dropped (the next command starts a new one).
    unawaited(
      p.exitCode.then((code) {
        if (identical(_displays[tag], up)) {
          _displays.remove(tag);
          debugPrint('Xvfb for $tag (:$n) exited by itself (code $code).');
        }
      }),
    );
    return up;
  }

  static Future<void> _drain(StreamIterator<String> lines, String tag) async {
    try {
      while (await lines.moveNext()) {}
    } on Object catch (e) {
      debugPrint('Xvfb ($tag) stdout: $e');
    }
  }

  /// Ends session [tag]'s display (the session is removed): the stop's outcome (verified), [Ended] with no pids
  /// when it had none. A display not closed stays listed for another try.
  static Future<KillOutcome> stopOf(String tag) async {
    final d = _displays[tag];
    final SupervisedProcess child;
    switch (d) {
      case null:
        return const Ended([]);
      case _Stopping(:final done):
        return done;
      case _Starting(:final done):
        final up = await done;
        if (up == null) {
          return switch (_displays[tag]) {
            _NotClosed(:final outcome) => outcome,
            _ => const Ended([]),
          };
        }
        return stopOf(tag);
      case _Up(child: final c) || _NotClosed(child: final c):
        child = c;
    }
    final done = child.stop();
    final stopping = _Stopping(done);
    _displays[tag] = stopping;
    final outcome = await done;
    if (identical(_displays[tag], stopping)) {
      if (outcome is Ended) {
        _displays.remove(tag);
      } else {
        debugPrint('NOT CLOSED: Xvfb ($tag): $outcome');
        _displays[tag] = _NotClosed(child, outcome);
      }
    }
    return outcome;
  }

  /// [stopOf] for callers that don't wait: the outcome is logged when it isn't a checked end.
  static void stop(String tag) {
    stopOf(tag).then(
      (o) => o is Ended ? null : debugPrint('NOT CLOSED: Xvfb ($tag): $o'),
      onError: (Object e) => debugPrint('NOT CLOSED: Xvfb ($tag): the stop failed: $e'),
    );
  }

  /// Ends every display (the app quits): the merged outcome.
  static Future<KillOutcome> stopAll() async =>
      KillOutcome.merge(await Future.wait([for (final tag in _displays.keys.toList()) stopOf(tag)]));
}
