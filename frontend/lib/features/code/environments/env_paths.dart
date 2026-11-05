// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../harness/events.dart';

/// The action fields that hold one path, and the one that holds a list.
const _pathKeys = ['path', 'to', 'cwd'];
const _listKey = 'paths';

/// [call] (from a CLI inside an environment) with its paths as this computer
/// sees them, via [toHost] (`ExecEnv.toHostPath`), so the permission rules,
/// file rows and diffs read the project's own folder. A path [toHost] can't
/// map (relative, or outside every shared folder) stays as it was: the rules
/// then read it as outside the project and ask. Tool output and Markdown
/// links in the agent's text aren't rewritten.
ActionCall actionToHost(ActionCall call, String? Function(String envPath) toHost) {
  final changes = <String, Object?>{};
  for (final k in _pathKeys) {
    if (call.action[k] case final String p when p.isNotEmpty) {
      if (toHost(p) case final h? when h != p) changes[k] = h;
    }
  }
  if (call.action[_listKey] case final List<Object?> list) {
    final mapped = [for (final p in list) p is String && p.isNotEmpty ? toHost(p) ?? p : p];
    for (var i = 0; i < list.length; i++) {
      if (mapped[i] != list[i]) {
        changes[_listKey] = mapped;
        break;
      }
    }
  }
  if (changes.isEmpty) return call;
  final raw = call.raw['action'];
  return ActionCall(
    id: call.id,
    raw: {
      ...call.raw,
      'action': {if (raw is Map) ...raw.cast<String, Object?>(), ...changes},
    },
    toolName: call.toolName,
    toolCallId: call.toolCallId,
    action: {...call.action, ...changes},
    thought: call.thought,
    summary: call.summary,
    risk: call.risk,
  );
}
