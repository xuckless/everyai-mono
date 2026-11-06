// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../domain/transcript.dart' show Transcript;
import '../harness/events.dart';

export 'runtime_profiles_stub.dart'
    if (dart.library.io) 'runtime_profiles_io.dart'
    show recordRuntime, sessionRuntimeProfiles;

// How long the project's commands take, for the session briefing: every
// harness's terminal calls and the app's own checks are timed, and the last
// three runs of each command are kept per project.

/// The project's file, relative to its root (git-excluded).
const runtimeProfilesPath = '.everyai/runtime-profiles.json';

/// An agent's command shorter than this isn't kept (every ls and grep would be).
const minRecordedRuntime = Duration(seconds: 3);

/// Durations kept per command.
const _keep = 3;

/// Commands kept per project (the most recently used).
const _maxCommands = 40;

/// Longer commands aren't kept: an inline script would fill the briefing.
const maxRecordedCommand = 120;

final _space = RegExp(r'\s+');
// Briefing text, so nothing that could break out of its `code` span or line.
final _unsafe = RegExp(r'[`\x00-\x1f\x7f]|<<');
final _cd = RegExp(r'''^cd\s+("[^"]*"|'[^']*'|[^\s&;|]+)\s*&&\s*''');
final _assign = RegExp(r'''^[A-Za-z_][A-Za-z0-9_]*=("[^"]*"|'[^']*'|\S*)\s+''');
final _timedOut = RegExp(r'timed out|timeout', caseSensitive: false);
final _tailPipe = RegExp(r'(\s+2>&1)?(\s*\|\s*(tail|head)\b[^|]*)*$');

/// [raw] as a profile key: whitespace collapsed, leading `cd <dir> &&` and
/// `VAR=value` dropped (the dir becomes the label), [worktree] and
/// [projectRoot] prefixes dropped, a trailing `2>&1 | tail …` dropped. The dir
/// is relative to the worktree (`frontend/`, '' for the root), from the `cd`s
/// or the harness's [cwd]. Null for an empty command or a dir outside both.
({String command, String dir})? normaliseCommand(
  String raw, {
  required String worktree,
  String projectRoot = '',
  String cwd = '',
}) {
  var cmd = raw.trim().replaceAll(_space, ' ');
  var dir = cwd.isEmpty ? worktree : _join(worktree, cwd);
  while (true) {
    if (_cd.firstMatch(cmd) case final m?) {
      dir = _join(dir, _unquote(m[1]!));
      cmd = cmd.substring(m.end);
    } else if (_assign.firstMatch(cmd) case final m?) {
      cmd = cmd.substring(m.end);
    } else {
      break;
    }
  }
  final roots = [worktree, projectRoot].where((r) => r.isNotEmpty).toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final r in roots) {
    cmd = cmd.replaceAll('$r/', '');
  }
  cmd = cmd.replaceFirst(_tailPipe, '').trim();
  if (!_keepable(cmd)) return null;
  for (final r in roots) {
    if (dir == r) return (command: cmd, dir: '');
    if (dir.startsWith('$r/')) return (command: cmd, dir: '${dir.substring(r.length + 1)}/');
  }
  return null;
}

/// Whether [command] may go into the briefing: short, one line, no backticks or heredoc.
bool _keepable(String command) =>
    command.isNotEmpty && command.length <= maxRecordedCommand && !_unsafe.hasMatch(command);

String _unquote(String s) =>
    s.length >= 2 && (s[0] == '"' || s[0] == "'") && s[s.length - 1] == s[0] ? s.substring(1, s.length - 1) : s;

/// [path] from [base], with `.` and `..` resolved.
String _join(String base, String path) {
  final parts = <String>[];
  for (final p in (path.startsWith('/') ? path : '$base/$path').split('/')) {
    if (p.isEmpty || p == '.') continue;
    if (p == '..') {
      if (parts.isNotEmpty) parts.removeLast();
    } else {
      parts.add(p);
    }
  }
  return '/${parts.join('/')}';
}

/// One command's last runs (milliseconds, oldest first).
typedef RuntimeProfile = ({String command, String dir, List<int> ms, int runs, int last});

/// The project's profiles, keyed by dir and command.
final class RuntimeProfiles {
  const RuntimeProfiles([this.entries = const {}]);

  final Map<String, RuntimeProfile> entries;

  /// The file's contents; anything malformed reads as none, and an entry the
  /// app wouldn't have written (see [normaliseCommand]) is dropped.
  factory RuntimeProfiles.fromJson(Object? json) {
    final list = json is Map ? json['commands'] : null;
    if (list is! List) return const RuntimeProfiles();
    final out = <String, RuntimeProfile>{};
    for (final e in list) {
      if (e is! Map) continue;
      final command = e['command'];
      final dir = e['dir'];
      final ms = e['ms'];
      if (command is! String || dir is! String || ms is! List || !_keepable(command)) continue;
      if (dir.isNotEmpty && (!_keepable(dir) || !dir.endsWith('/'))) continue;
      final kept = [...ms.whereType<int>()];
      if (kept.isEmpty) continue;
      out['$dir\t$command'] = (
        command: command,
        dir: dir,
        ms: kept.length > _keep ? kept.sublist(kept.length - _keep) : kept,
        runs: e['runs'] is int ? e['runs'] as int : kept.length,
        last: e['last'] is int ? e['last'] as int : 0,
      );
    }
    return RuntimeProfiles(out);
  }

  Map<String, Object?> toJson() => {
    'commands': [
      for (final p in entries.values) {'command': p.command, 'dir': p.dir, 'ms': p.ms, 'runs': p.runs, 'last': p.last},
    ],
  };

  /// With [took] added to [command] in [dir]: its last [_keep] runs, and only the [_maxCommands] most recent commands.
  RuntimeProfiles record(String command, String dir, Duration took, DateTime now) {
    if (!_keepable(command) || (dir.isNotEmpty && !_keepable(dir))) return this;
    final key = '$dir\t$command';
    final old = entries[key];
    final ms = [...?old?.ms, took.inMilliseconds];
    final next = {
      ...entries,
      key: (
        command: command,
        dir: dir,
        ms: ms.length > _keep ? ms.sublist(ms.length - _keep) : ms,
        runs: (old?.runs ?? 0) + 1,
        last: now.millisecondsSinceEpoch,
      ),
    };
    if (next.length > _maxCommands) {
      final byAge = next.entries.toList()..sort((a, b) => a.value.last.compareTo(b.value.last));
      for (final e in byAge.take(next.length - _maxCommands)) {
        next.remove(e.key);
      }
    }
    return RuntimeProfiles(next);
  }
}

/// Test runners that, given no target, run everything.
const _fullRunners = {
  'flutter test',
  'dart test',
  'npm test',
  'npm run test',
  'pnpm test',
  'yarn test',
  'jest',
  'npx jest',
  'vitest',
  'vitest run',
  'npx vitest',
  'npx vitest run',
  'pytest',
  'cargo test',
  'go test ./...',
};

int _median(List<int> ms) {
  final s = [...ms]..sort();
  return s.length.isOdd ? s[s.length ~/ 2] : (s[s.length ~/ 2 - 1] + s[s.length ~/ 2]) ~/ 2;
}

/// [ms] as `12s`, `4m 2s` or `1h 3m`.
String formatRuntime(int ms) {
  final s = (ms / 1000).round();
  if (s < 1) return '<1s';
  if (s < 60) return '${s}s';
  if (s < 3600) return '${s ~/ 60}m ${s % 60}s';
  return '${s ~/ 3600}h ${s % 3600 ~/ 60}m';
}

/// The briefing's lines, slowest first (then the most used), at most [max]: for example
/// "`flutter test` (full, frontend/): ~4m 10s (last 3: 4m 2s, 4m 10s, 4m 31s)".
List<String> renderProfiles(RuntimeProfiles p, {int max = 12}) {
  final list = p.entries.values.toList()
    ..sort((a, b) {
      final byTime = _median(b.ms).compareTo(_median(a.ms));
      return byTime != 0 ? byTime : b.runs.compareTo(a.runs);
    });
  return [
    for (final e in list.take(max))
      () {
        final labels = [if (_fullRunners.contains(e.command)) 'full', if (e.dir.isNotEmpty) e.dir];
        final label = labels.isEmpty ? '' : ' (${labels.join(', ')})';
        final runs = e.ms.length == 1 ? '1 run' : 'last ${e.ms.length}: ${e.ms.map(formatRuntime).join(', ')}';
        return '`${e.command}`$label: ~${formatRuntime(_median(e.ms))} ($runs)';
      }(),
  ];
}

/// Times terminal calls from when they may run (not while they wait for
/// approval) to their result. Events carry no timestamps, so the clock is
/// read as they arrive.
final class CommandTimer {
  CommandTimer({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final _open = <String, ({String command, String cwd, DateTime? start})>{};
  final _byToolCall = <String, String>{};

  /// A call arrived; [waiting] while it is pending or held for approval.
  void call(ActionCall c, {required bool waiting}) {
    if (c.actionKind != 'TerminalAction' || _open.containsKey(c.id)) return;
    if (c.str('command').trim().isEmpty || c.action['is_input'] == true || c.action['run_in_background'] == true) {
      return;
    }
    _open[c.id] = (command: c.str('command'), cwd: c.str('cwd'), start: waiting ? null : _now());
    if (c.toolCallId.isNotEmpty) _byToolCall[c.toolCallId] = c.id;
  }

  /// Keeps the clock stopped for the calls in [waiting] and starts it for the
  /// others. Drivers send a call before they ask about it, so a call timed
  /// from arrival is reset when it turns out to wait.
  void released(Set<String> waiting) {
    for (final e in _open.entries.toList()) {
      final wait = waiting.contains(e.key);
      if (wait == (e.value.start == null)) continue;
      _open[e.key] = (command: e.value.command, cwd: e.value.cwd, start: wait ? null : _now());
    }
  }

  /// The finished command and how long it ran, or null: not one of ours, never
  /// started, rejected, stopped or timed out (it ran as long as the limit, not the command).
  ({String command, String cwd, Duration took})? result(ToolResult r) {
    final id = r.actionId.isNotEmpty ? r.actionId : _byToolCall[r.toolCallId] ?? '';
    final open = _open.remove(id);
    _byToolCall.removeWhere((_, v) => v == id);
    final start = open?.start;
    if (open == null || start == null || r.outcome == ToolOutcome.rejected) return null;
    if (r.text.trimLeft().startsWith('Stopped')) return null;
    if (r.outcome == ToolOutcome.error && _timedOut.hasMatch(r.text)) return null;
    return (command: open.command, cwd: open.cwd, took: _now().difference(start));
  }

  /// Feeds [event], with the [transcript] it made, to the timer: a call's
  /// clock runs only while it isn't pending or held. The finished command, as [result].
  ({String command, String cwd, Duration took})? observe(HarnessEvent event, Transcript transcript) {
    final waiting = {
      for (final c in [...transcript.pending, ...transcript.held]) c.id,
    };
    if (event is ActionCall) call(event, waiting: waiting.contains(event.id));
    released(waiting);
    return event is ToolResult ? result(event) : null;
  }

  /// Forgets the open calls (the user stopped the run).
  void clear() {
    _open.clear();
    _byToolCall.clear();
  }
}
