// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../../features/code/harness/everyai/shell_io.dart' show killTree;
import 'child_processes.dart';

final class _Child {
  _Child(this.pid, this.label, this.command);
  final int pid;
  final String label;

  /// The executable's file name, which the watchdog checks before it kills (a pid can be reused).
  final String command;
  var phase = ChildPhase.running;
  Future<void>? stopping;
}

final _children = <int, _Child>{};

void _apply(_Child c, ChildEvent e) {
  final next = nextChildPhase(c.phase, e);
  if (next == null) return;
  c.phase = next;
  if (next == ChildPhase.exited) _children.remove(c.pid);
  _writeList();
}

void track(int pid, {required String label, required String executable, required Future<int> exited}) {
  final c = _children[pid] = _Child(pid, label, executable.split(Platform.pathSeparator).last);
  _writeList();
  _ensureWatchdog();
  unawaited(exited.then((_) => _apply(c, ChildEvent.exited), onError: (Object _) => _apply(c, ChildEvent.exited)));
}

ChildPhase? phaseOf(int pid) => _children[pid]?.phase;

Map<int, String> get tracked => {for (final c in _children.values) c.pid: c.label};

Future<void> stop(int pid) {
  final c = _children[pid];
  if (c == null) return Future.value();
  if (c.phase == ChildPhase.stopping) return c.stopping!;
  _apply(c, ChildEvent.stop);
  return c.stopping = _kill(c);
}

Future<void> _kill(_Child c) async {
  try {
    await killChildTree(c.pid);
  } on Object catch (e) {
    debugPrint('Stopping ${c.label} (${c.pid}) failed: $e');
  }
  // killTree ends with SIGKILL: the process is gone even when its exit hasn't been reported yet.
  _apply(c, ChildEvent.exited);
}

/// How a child's tree is ended; tests replace it.
@visibleForTesting
Future<void> Function(int pid) killChildTree = killTree;

Future<void> stopAll() async {
  await Future.wait([for (final pid in _children.keys.toList()) stop(pid)]);
  _deleteList();
}

// ------------------------------------------------------------------ watchdog

/// The list the watchdog reads: one `pid command` line per live child.
File get _list => File('${Directory.systemTemp.path}/everyai-children-$pid.list');

var _watching = false;

/// Whether the watchdog may start (tests that only exercise the registry turn it off).
@visibleForTesting
bool watchdogEnabled = !Platform.isWindows;

void _writeList() {
  if (!_watching) return;
  try {
    _list.writeAsStringSync([for (final c in _children.values) '${c.pid} ${c.command}\n'].join());
  } on Object {
    // A full or read-only temp folder: the quit path still stops them.
  }
}

void _deleteList() {
  try {
    if (_list.existsSync()) _list.deleteSync();
  } on Object {
    // Gone already.
  }
}

/// Waits for this app process to end; then ends the children still listed whose command still matches.
const _watchdogScript = r'''
app=$1; f=$2
while kill -0 "$app" 2>/dev/null; do sleep 2; done
[ -f "$f" ] || exit 0
end() {
  while read -r p c; do
    [ -n "$p" ] || continue
    now=$(ps -o comm= -p "$p" 2>/dev/null)
    case "$now" in *"$c"*) pkill -"$1" -P "$p" 2>/dev/null; kill -"$1" "$p" 2>/dev/null;; esac
  done < "$f"
}
end TERM; sleep 2; end KILL
rm -f "$f"
''';

void _ensureWatchdog() {
  if (_watching || !watchdogEnabled) return;
  _watching = true;
  _writeList();
  unawaited(
    Process.start(
      '/bin/sh',
      ['-c', _watchdogScript, 'everyai-watchdog', '$pid', _list.path],
      mode: ProcessStartMode.detached,
    ).then<void>((_) {}, onError: (Object e) => debugPrint('The child-process watchdog did not start: $e')),
  );
}
