import 'dart:convert';

import '../harness/events.dart';
import 'agent_mode.dart';

/// How many identical steps in a row make a loop.
const doomLoopRepeats = 3;

/// Spots an agent calling the same tool with the same input over and over.
/// Feed it every [ActionCall] in order; [add] says when the latest one is the
/// [doomLoopRepeats]th identical call in a row. Planning, thinking, finishing
/// and the client tools that talk to the user never count.
final class DoomLoopDetector {
  final _seen = <String>{};
  String? _last;
  var _run = 0;

  /// The tool call that made the latest loop (for the card's wording).
  ActionCall? looped;

  /// Whether [call] completes a loop. Each call counts once, so a replayed
  /// history can't count twice; after a loop is reported the count starts over.
  bool add(ActionCall call) {
    if (!_counts(call) || !_seen.add(call.id)) return false;
    final sig = signature(call);
    _run = sig == _last ? _run + 1 : 1;
    _last = sig;
    if (_run < doomLoopRepeats) return false;
    looped = call;
    reset();
    return true;
  }

  /// The user spoke or answered: start counting again.
  void reset() {
    _last = null;
    _run = 0;
  }

  static bool _counts(ActionCall c) =>
      !isClientTool(c) && !const {'ThinkAction', 'FinishAction', 'TaskTrackerAction'}.contains(c.actionKind);

  /// The tool and its input, with whitespace in strings collapsed and keys sorted,
  /// so `ls  -la` and `ls -la` are the same step.
  static String signature(ActionCall c) => '${c.toolName}\u0000${jsonEncode(_norm(c.action))}';

  static Object? _norm(Object? v) => switch (v) {
    final Map<Object?, Object?> m => {for (final k in (m.keys.map((k) => '$k').toList()..sort())) k: _norm(m[k])},
    final List<Object?> l => [for (final e in l) _norm(e)],
    final String s => s.trim().replaceAll(RegExp(r'\s+'), ' '),
    _ => v,
  };
}

/// A short phrase for what repeated ("`flutter test`", "view lib/a.dart").
String loopedStep(ActionCall call) {
  final command = call.str('command');
  final path = call.str('path');
  final text = switch (call.actionKind) {
    'TerminalAction' => command,
    'FileEditorAction' => '$command $path'.trim(),
    _ => call.summary.isNotEmpty ? call.summary : call.toolName,
  };
  final one = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return one.length > 80 ? '${one.substring(0, 79)}…' : one;
}
