import 'package:flutter/foundation.dart';

import '../harness/events.dart';
import 'agent_mode.dart';
import 'shell_readonly.dart';

/// The app's command policy for Code sessions. The agent server confirms
/// every action (see [AgentMode.confirmationPolicy]); the app then decides,
/// in this order:
///
/// 1. client tools (question cards, plans) go to their own UI;
/// 2. the hardline floor ([floorReason]) blocks a short list of
///    catastrophic commands in every mode, Full auto included;
/// 3. the user's `deny` rules block what they match;
/// 4. Plan mode refuses anything that isn't read-only;
/// 5. read-only actions run;
/// 6. dangerous actions ([dangerReason], [editDangerReason]) always ask,
///    except in Full auto;
/// 7. `allow` rules and approvals remembered for the session run, but only
///    for simple commands (one command, nothing chained);
/// 8. otherwise the mode decides.
///
/// Like any check on a shell string this is defence in depth, not a
/// sandbox: the agent runs as the user, in the session's worktree.
enum Verdict { allow, ask, deny }

/// Which step of the policy decided.
enum DecisionSource { clientTool, floor, rule, plan, readOnly, dangerous, allowRule, mode }

@immutable
final class Decision {
  const Decision(this.verdict, this.source, {this.why = '', this.rule});

  final Verdict verdict;
  final DecisionSource source;

  /// For the floor and dangerous actions: what the action does, in a few words.
  final String why;

  /// The permission rule that matched.
  final String? rule;

  @override
  String toString() => 'Decision($verdict, $source${why.isEmpty ? '' : ', $why'}${rule == null ? '' : ', $rule'})';
}

/// User permission rules. A rule is a glob on a command (`npm test *`, also
/// written `Bash(npm test *)`) or on a path relative to the project:
/// `Edit(src/**)`, `Read(.env*)`. In globs `*` matches anything (within a
/// path segment for paths), `**` crosses folders, `?` one character, and a
/// trailing ` *` also matches the bare command. A path glob without a `/`
/// matches the file name in any folder.
@immutable
final class PermissionRules {
  const PermissionRules({this.allow = const [], this.deny = const []});

  static const none = PermissionRules();

  final List<String> allow;
  final List<String> deny;

  bool get isEmpty => allow.isEmpty && deny.isEmpty;

  PermissionRules operator +(PermissionRules o) =>
      PermissionRules(allow: _union(allow, o.allow), deny: _union(deny, o.deny));

  static List<String> _union(List<String> a, List<String> b) => [
    ...a,
    for (final r in b)
      if (!a.contains(r)) r,
  ];

  factory PermissionRules.fromJson(Object? json) {
    if (json is! Map<String, Object?>) return none;
    List<String> strings(Object? v) => [
      if (v is List<Object?>)
        for (final s in v)
          if (s is String && s.trim().isNotEmpty) s.trim(),
    ];
    return PermissionRules(allow: strings(json['allow']), deny: strings(json['deny']));
  }

  Map<String, Object?> toJson() => {'allow': allow, 'deny': deny};
}

/// Decides what happens to the agent's actions in one session.
@immutable
final class PermissionPolicy {
  const PermissionPolicy({this.rules = PermissionRules.none, this.session = const {}, this.workingDir});

  /// Settings and stored rules (global, then project).
  final PermissionRules rules;

  /// Patterns the user approved "for this session" (see [rememberPattern]).
  final Set<String> session;

  /// The session's folder; paths in rules are relative to it.
  final String? workingDir;

  Decision decide(ActionCall call, AgentMode mode) {
    if (isClientTool(call)) return const Decision(Verdict.allow, DecisionSource.clientTool);
    final command = _command(call);
    if (command != null) {
      if (floorReason(command) case final why?) return Decision(Verdict.deny, DecisionSource.floor, why: why);
    }
    if (_matching(call, rules.deny, allowing: false) case final rule?) {
      return Decision(Verdict.deny, DecisionSource.rule, rule: rule);
    }
    final readOnly = AgentMode.isReadOnly(call);
    if (mode == AgentMode.plan && !readOnly) return const Decision(Verdict.deny, DecisionSource.plan);
    if (readOnly) return const Decision(Verdict.allow, DecisionSource.readOnly);
    final edit = _editPath(call);
    final danger = command != null
        ? dangerReason(command)
        : edit != null
        ? editDangerReason(edit, workingDir: workingDir)
        : null;
    if (danger != null && mode != AgentMode.fullAuto) {
      return Decision(Verdict.ask, DecisionSource.dangerous, why: danger);
    }
    if (danger == null) {
      if (_matching(call, [...rules.allow, ...session], allowing: true) case final rule?) {
        return Decision(Verdict.allow, DecisionSource.allowRule, rule: rule);
      }
    }
    final allowed = switch (mode) {
      AgentMode.fullAuto => true,
      AgentMode.autoEdit => edit != null,
      AgentMode.ask || AgentMode.plan => false,
    };
    return Decision(allowed ? Verdict.allow : Verdict.ask, DecisionSource.mode, why: danger ?? '');
  }

  /// One answer for everything the server is waiting on (it approves or
  /// rejects all pending actions at once): a refusal with the text the
  /// agent reads, approval, or null to ask the user.
  ({bool accept, String? reason})? decideAll(List<ActionCall> calls, AgentMode mode) {
    if (calls.isEmpty) return null;
    final decisions = [for (final c in calls) (c, decide(c, mode))];
    final blocked = [
      for (final (c, d) in decisions)
        if (d.source == DecisionSource.floor || d.source == DecisionSource.rule) (c, d),
    ];
    if (blocked.isNotEmpty) return (accept: false, reason: policyDenial(blocked, batch: calls.length));
    if (decisions.any((e) => e.$2.source == DecisionSource.plan)) {
      return (accept: false, reason: AgentMode.planRefusal);
    }
    if (decisions.every((e) => e.$2.verdict == Verdict.allow)) return (accept: true, reason: null);
    return null;
  }

  /// The first rule in [patterns] that matches [call]. Allow rules only
  /// match a simple command: a chain (`a && b`, pipes, `;`) or anything the
  /// parser can't vouch for is never approved by a rule.
  String? _matching(ActionCall call, List<String> patterns, {required bool allowing}) {
    if (patterns.isEmpty) return null;
    final command = _command(call);
    final edit = _editPath(call);
    final read = _readPath(call);
    for (final raw in patterns) {
      final rule = _Rule.parse(raw);
      if (rule == null) continue;
      final hit = switch (rule.kind) {
        _RuleKind.command when command != null =>
          allowing ? _allowsCommand(rule.glob, command) : _deniesCommand(rule.glob, command),
        _RuleKind.edit when edit != null => _pathMatches(rule.glob, _relative(edit)),
        _RuleKind.read when read != null => _pathMatches(rule.glob, _relative(read)),
        _ => false,
      };
      if (hit) return raw;
    }
    return null;
  }

  String _relative(String path) => relativeTo(path, workingDir);
}

/// [path] relative to [dir] when it is inside it, else unchanged.
String relativeTo(String path, String? dir) {
  if (dir == null || dir.isEmpty) return path;
  final base = dir.endsWith('/') ? dir : '$dir/';
  return path.startsWith(base) ? path.substring(base.length) : path;
}

/// The shell command of a terminal action (not keystrokes to a running process).
String? _command(ActionCall call) =>
    call.actionKind == 'TerminalAction' && call.action['is_input'] != true ? call.str('command') : null;

/// The file a write would change.
String? _editPath(ActionCall call) => switch (call.actionKind) {
  'FileEditorAction' when call.str('command') != 'view' => call.str('path'),
  'EditAction' || 'WriteFileAction' => call.str('path'),
  _ => null,
};

String? _readPath(ActionCall call) => switch (call.actionKind) {
  'FileEditorAction' when call.str('command') == 'view' => call.str('path'),
  'ReadFileAction' => call.str('path'),
  _ => null,
};

enum _RuleKind { command, edit, read }

final class _Rule {
  const _Rule(this.kind, this.glob);
  final _RuleKind kind;
  final String glob;

  static final _wrapped = RegExp(r'^(\w+)\((.*)\)$', dotAll: true);

  static _Rule? parse(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    final m = _wrapped.firstMatch(s);
    if (m == null) return _Rule(_RuleKind.command, s);
    final glob = m.group(2)!.trim();
    if (glob.isEmpty) return null;
    return switch (m.group(1)!.toLowerCase()) {
      'bash' || 'shell' || 'command' => _Rule(_RuleKind.command, glob),
      'edit' || 'write' => _Rule(_RuleKind.edit, glob),
      'read' => _Rule(_RuleKind.read, glob),
      _ => null,
    };
  }
}

/// Whether [glob] matches [text]. Command globs let `*` cross anything;
/// path globs keep `*` inside one folder.
bool globMatches(String glob, String text, {bool path = false}) {
  final b = StringBuffer('^');
  var i = 0;
  var g = glob;
  var optionalTail = false;
  if (!path && g.endsWith(' *')) {
    g = g.substring(0, g.length - 2);
    optionalTail = true;
  }
  while (i < g.length) {
    final c = g[i];
    if (c == '*') {
      if (i + 1 < g.length && g[i + 1] == '*') {
        // `**/` also matches no folder at all.
        if (path && i + 2 < g.length && g[i + 2] == '/') {
          b.write('(?:.*/)?');
          i += 3;
        } else {
          b.write('.*');
          i += 2;
        }
        continue;
      }
      b.write(path ? '[^/]*' : '.*');
    } else if (c == '?') {
      b.write(path ? '[^/]' : '.');
    } else {
      b.write(RegExp.escape(c));
    }
    i++;
  }
  if (optionalTail) b.write('(?: .*)?');
  b.write(r'$');
  return RegExp(b.toString(), dotAll: true).hasMatch(text);
}

bool _pathMatches(String glob, String path) {
  if (globMatches(glob, path, path: true)) return true;
  // `.env` matches the name in any folder, the way .gitignore does.
  if (!glob.contains('/')) return globMatches(glob, path.split('/').last, path: true);
  return false;
}

/// Deny rules match any part of the command, wherever it hides (chains,
/// `$(…)`, `sh -c "…"`), or the command as a whole.
bool _deniesCommand(String glob, String command) {
  final whole = _collapse(_unquote(command));
  if (globMatches(glob, whole)) return true;
  return commandParts(command).any((p) => globMatches(glob, p));
}

/// Allow rules match only a simple command, every word as the parser reads it.
bool _allowsCommand(String glob, String command) {
  final segments = shellSegments(command);
  if (segments == null || segments.length != 1) return false;
  return globMatches(glob, segments.single.join(' '));
}

// ---------------------------------------------------------------------------
// Splitting commands for the floor, the classifier and deny rules.

/// Every simple command inside [raw], normalized for matching: quotes
/// removed, spaces collapsed, and wrappers that only change how the command
/// runs (`sudo`, `env X=1`, `nohup`, `timeout 5`, `/bin/`) stripped off the
/// front. Unlike [shellSegments] this never gives up: it also looks inside
/// `$(…)`, backticks and `sh -c "…"`/`eval` arguments.
List<String> commandParts(String raw) => _parts(raw, 0);

List<String> _parts(String raw, int depth) {
  final pieces = <String>[];
  final b = StringBuffer();
  String? quote;
  void flush() {
    final t = b.toString().trim();
    if (t.isNotEmpty) pieces.add(t);
    b.clear();
  }

  for (var i = 0; i < raw.length; i++) {
    final c = raw[i];
    if (quote == "'") {
      if (c == "'") quote = null;
      b.write(c);
      continue;
    }
    if (c == r'\' && i + 1 < raw.length) {
      b
        ..write(c)
        ..write(raw[i + 1]);
      i++;
      continue;
    }
    // Command substitution starts a new command, even inside double quotes.
    if (c == '`' || (c == r'$' && i + 1 < raw.length && raw[i + 1] == '(')) {
      flush();
      quote = null;
      if (c == r'$') i++;
      continue;
    }
    if (quote == '"') {
      if (c == '"') quote = null;
      b.write(c);
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      b.write(c);
      continue;
    }
    if (';&|\n()'.contains(c)) {
      flush();
      continue;
    }
    b.write(c);
  }
  flush();
  final out = <String>[];
  for (final p in pieces) {
    final stripped = _stripWrappers(p);
    final normalized = _collapse(_unquote(stripped));
    if (normalized.isNotEmpty) out.add(normalized);
    if (depth < 3) {
      if (_innerScript(stripped) case final inner?) out.addAll(_parts(inner, depth + 1));
    }
  }
  return out;
}

final _wrappers = [
  RegExp(r'^\\'),
  RegExp(
    r'^[A-Za-z_][A-Za-z0-9_]*=("[^"]*"|'
    "'[^']*'"
    r'|\S*)\s+',
  ),
  RegExp(r'^(sudo|doas)(\s+-\S+)*\s+'),
  RegExp(r'^(command|builtin|exec|nohup|time|nice|caffeinate|stdbuf)(\s+-\S+)*\s+'),
  RegExp(r'^env(\s+-\S+|\s+[A-Za-z_][A-Za-z0-9_]*=\S*)*\s+'),
  RegExp(r'^(timeout|gtimeout)(\s+-\S+)*\s+\S+\s+'),
  RegExp(r'^xargs(\s+-[IdLnPsEJ]\s+\S+|\s+-\S+)*\s+'),
  RegExp(r'^/(?:[\w.+-]+/)+(?=[\w.+-]+(\s|$))'),
];

String _stripWrappers(String s) {
  var out = s.trim();
  for (var changed = true; changed;) {
    changed = false;
    for (final w in _wrappers) {
      final next = out.replaceFirst(w, '');
      if (next != out) {
        out = next.trimLeft();
        changed = true;
      }
    }
  }
  return out;
}

String _unquote(String s) => s.replaceAll(RegExp(r'''["']'''), '');

String _collapse(String s) => s.trim().replaceAll(RegExp(r'\s+'), ' ');

final _shellC = RegExp(r'^(?:\S*/)?(?:ba|z|da|k|fi)?sh\s+(?:-\w+\s+)*-\w*c\s+(.+)$', dotAll: true);
final _evalArg = RegExp(r'^eval\s+(.+)$', dotAll: true);

/// The script `sh -c '…'` or `eval '…'` runs, quotes removed.
String? _innerScript(String s) {
  final m = _shellC.firstMatch(s) ?? _evalArg.firstMatch(s);
  if (m == null) return null;
  var arg = m.group(1)!.trim();
  if (arg.length >= 2 && (arg[0] == "'" || arg[0] == '"')) {
    final end = arg.lastIndexOf(arg[0]);
    if (end > 0) arg = arg.substring(1, end);
  }
  return arg;
}

List<String> _words(String part) => part.split(' ');

bool _recursive(List<String> args, {bool lowerR = true}) => args.any(
  (a) =>
      a == '--recursive' ||
      (!a.startsWith('--') && RegExp(lowerR ? r'^-[a-zA-Z]*[rR][a-zA-Z]*$' : r'^-[a-zA-Z]*R[a-zA-Z]*$').hasMatch(a)),
);

final _systemDir = RegExp(
  r'^/(Users|home|root|etc|usr|bin|sbin|lib|lib64|var|System|Library|Applications|opt|private|boot|dev|Volumes|'
  r'proc|sys|cores|nix)(/\*)?$',
);
final _homeDir = RegExp(r'^/(Users|home)/[^/*]+(/\*)?$');

/// The file system root, a home folder, or a system folder.
bool _isRootTarget(String arg) {
  var t = arg;
  while (t.length > 1 && t.endsWith('/')) {
    t = t.substring(0, t.length - 1);
  }
  if (t == '//' || t == '/.') t = '/';
  const exact = {'/', '/*', '~', '~/*', r'$HOME', r'${HOME}', r'$HOME/*', r'${HOME}/*', '~/.', '/..'};
  return exact.contains(t) || _systemDir.hasMatch(t) || _homeDir.hasMatch(t);
}

/// `git` with its global options skipped: the subcommand and what follows.
(String, List<String>)? _git(List<String> w) {
  if (w.isEmpty || w.first != 'git') return null;
  var i = 1;
  while (i < w.length && w[i].startsWith('-')) {
    i += const {'-C', '-c', '--git-dir', '--work-tree', '--namespace'}.contains(w[i]) ? 2 : 1;
  }
  if (i >= w.length) return null;
  return (w[i], w.sublist(i + 1));
}

bool _shortFlag(List<String> args, String letter) =>
    args.any((a) => !a.startsWith('--') && RegExp('^-[a-zA-Z]*$letter[a-zA-Z]*\$').hasMatch(a));

bool _hasFlag(List<String> args, Set<String> flags) => args.any((a) => flags.any((f) => a == f || a.startsWith('$f=')));

/// A git push that overwrites or deletes remote history.
({bool force, bool delete, bool mirror, bool main})? _push(List<String> w) {
  final git = _git(w);
  if (git == null || git.$1 != 'push') return null;
  final args = git.$2;
  final positionals = args.where((a) => !a.startsWith('-')).toList();
  final force =
      _hasFlag(args, {'--force', '--force-with-lease'}) ||
      _shortFlag(args, 'f') ||
      positionals.any((p) => p.startsWith('+'));
  final delete =
      _hasFlag(args, {'--delete', '--prune'}) || _shortFlag(args, 'd') || positionals.any((p) => p.startsWith(':'));
  final main = positionals.skip(1).any((p) => RegExp(r'(^|[:/+])(main|master)$').hasMatch(p));
  return (force: force, delete: delete, mirror: args.contains('--mirror'), main: main);
}

final _forkBomb = RegExp(r'(\w+|:)\(\)\{\1\|\1&\};?\1');
final _diskDevice = RegExp(r'/dev/(r?disk\d|sd[a-z]|nvme\d|hd[a-z]|mmcblk\d|xvd[a-z]|vd[a-z])');
final _toRootShell = RegExp(
  r'\b(curl|wget|fetch)\b[^|;&]*\|\s*(sudo|doas)\s+(-\S+\s+)*(\S*/)?(ba|z|da|k|fi)?sh\b|'
  r'''\b(sudo|doas)\s+(\S*/)?(ba|z|da|k)?sh\s+-c\s+["']?\$\(\s*(curl|wget)''',
);

/// Why [command] is never run, in any mode, or null. The list is short on
/// purpose: things no coding task needs and nobody can undo (wiping the
/// disk or home folder, formatting, fork bombs, shutting down, force-pushing
/// main). Matching is on command position, so `git commit -m "rm -rf /"`
/// is fine.
String? floorReason(String command) {
  final squeezed = command.replaceAll(RegExp(r'\s+'), '');
  if (_forkBomb.hasMatch(squeezed)) return 'a fork bomb';
  if (_toRootShell.hasMatch(command)) return 'pipes a download into a root shell';
  for (final part in commandParts(command)) {
    final w = _words(part);
    final args = w.sublist(1);
    final targets = args.where((a) => !a.startsWith('-'));
    switch (w.first) {
      case 'rm' when args.contains('--no-preserve-root'):
        return 'deletes the whole file system';
      case 'rm' when _recursive(args) && targets.any(_isRootTarget):
        return 'deletes the file system, a home folder or a system folder';
      case 'chmod' || 'chown' || 'chgrp' when _recursive(args, lowerR: false) && targets.any(_isRootTarget):
        return 'changes ownership or permissions of a system or home folder';
      case 'find'
          when args.isNotEmpty &&
              _isRootTarget(args.firstWhere((a) => !a.startsWith('-'), orElse: () => '')) &&
              (args.contains('-delete') || RegExp(r'-exec(dir)? (\S*/)?rm ').hasMatch(part)):
        return 'deletes files across a system or home folder';
      case 'dd' when args.any((a) => a.startsWith('of=/dev/')):
        return 'writes raw data to a device';
      case 'diskutil'
          when args.isNotEmpty &&
              const {
                'eraseDisk', 'eraseVolume', 'partitionDisk', 'zeroDisk', 'randomDisk', 'secureErase', 'reformat', //
                'splitPartition', 'mergePartitions', 'deleteVolume',
              }.contains(args.first):
        return 'erases or repartitions a disk';
      case 'shutdown' || 'reboot' || 'halt' || 'poweroff':
        return 'shuts down or restarts the computer';
      case 'init' when args.length == 1 && (args.first == '0' || args.first == '6'):
        return 'shuts down or restarts the computer';
      case 'systemctl' || 'launchctl'
          when args.any((a) => const {'poweroff', 'reboot', 'halt', 'kexec', 'userspace'}.contains(a)):
        return 'shuts down or restarts the computer';
      case 'kill' when args.length >= 2 && args.skip(1).contains('-1'):
        return 'kills every process you own';
    }
    if (RegExp(r'^(mkfs(\.\w+)?|newfs(_\w+)?|wipefs|fdisk|sfdisk|gdisk|cfdisk|parted)$').hasMatch(w.first)) {
      return 'formats or repartitions a disk';
    }
    if (RegExp(r'>\s*' + _diskDevice.pattern).hasMatch(part)) return 'writes raw data to a disk device';
    final push = _push(w);
    if (push != null && push.main && (push.force || push.delete)) {
      return 'force-pushes or deletes main/master on the remote';
    }
  }
  return null;
}

final _pipeToShell = RegExp(
  r'\b(curl|wget|fetch)\b[^|;&]*\|\s*(\S*/)?(ba|z|da|k|fi)?sh\b|'
  r'(ba|z)?sh\s+<\(\s*(curl|wget)|'
  r'''-c\s+["']?\$\(\s*(curl|wget)''',
);
final _sql = RegExp(r'\b(drop\s+(table|database|schema)|truncate\s+table)\b', caseSensitive: false);
final _homeSecrets = RegExp(
  r'>>?\s*(~|\$HOME|\$\{HOME\})/\.(ssh|zshrc|zshenv|zprofile|bashrc|bash_profile|profile|gitconfig|aws|kube|netrc|'
  r'gnupg|config/gh)',
);

/// Why [command] needs the user's eyes even when rules or the mode would
/// run it, or null. Full auto skips this check (the floor still holds).
String? dangerReason(String command) {
  if (floorReason(command) case final why?) return why;
  if (RegExp(r'(^|[\s;&|(`])(sudo|doas)\s').hasMatch(command)) return 'runs as administrator';
  if (_pipeToShell.hasMatch(command)) return 'runs a script downloaded from the internet';
  if (_sql.hasMatch(command)) return 'drops database tables';
  if (_homeSecrets.hasMatch(command)) return 'writes to a sensitive file in your home folder';
  if (RegExp(r'\bxargs\b[^|;&]*\brm\b').hasMatch(command)) return 'deletes files';
  for (final part in commandParts(command)) {
    final w = _words(part);
    final args = w.sublist(1);
    final why = switch (w.first) {
      'rm' when _recursive(args) => 'deletes files recursively',
      'chmod' || 'chown' || 'chgrp' when _recursive(args, lowerR: false) => 'changes permissions recursively',
      'chmod' when args.any((a) => RegExp(r'^0?777$').hasMatch(a)) => 'makes files writable by everyone',
      'eval' => 'runs a computed command',
      'dd' || 'shred' || 'truncate' => 'overwrites data',
      'kill' when args.any((a) => const {'-9', '-KILL', '-SIGKILL', '-s'}.contains(a)) => 'force-kills processes',
      'pkill' || 'killall' => 'kills processes by name',
      'find' when args.contains('-delete') || RegExp(r'-exec(dir)? (\S*/)?rm ').hasMatch(part) =>
        'deletes the files it finds',
      'rsync' when args.any((a) => a.startsWith('--delete')) => 'deletes files at the destination',
      'crontab' when args.contains('-r') => 'removes scheduled jobs',
      'launchctl' when args.any((a) => const {'unload', 'remove', 'bootout', 'disable'}.contains(a)) =>
        'changes system services',
      'defaults' when args.contains('delete') => 'deletes system preferences',
      'security' when args.any((a) => a.startsWith('delete-')) => 'deletes keychain items',
      'docker' when args.any((a) => a == 'prune') || (args.length >= 2 && args[0] == 'volume' && args[1] == 'rm') =>
        'deletes Docker data',
      'npm' ||
      'pnpm' ||
      'yarn' ||
      'cargo' ||
      'twine' when args.any((a) => a == 'publish' || a == 'upload') => 'publishes a package',
      'dart' || 'flutter' when args.length >= 2 && args[0] == 'pub' && args[1] == 'publish' => 'publishes a package',
      'gem' when args.isNotEmpty && args.first == 'push' => 'publishes a package',
      'docker' when args.isNotEmpty && args.first == 'push' => 'publishes an image',
      'gh' when _gh(args) => 'changes GitHub (merges, releases or deletes)',
      _ => null,
    };
    if (why != null) return why;
    if (_gitDanger(w) case final why?) return why;
  }
  return null;
}

bool _gh(List<String> args) {
  if (args.length < 2) return false;
  return switch (args[0]) {
    'repo' => const {'delete', 'archive', 'rename', 'edit'}.contains(args[1]),
    'pr' => const {'merge', 'close'}.contains(args[1]),
    'release' => const {'create', 'delete', 'upload'}.contains(args[1]),
    'secret' || 'variable' => const {'set', 'delete', 'remove'}.contains(args[1]),
    _ => false,
  };
}

String? _gitDanger(List<String> w) {
  if (_push(w) case final p? when p.force || p.delete || p.mirror) return 'rewrites or deletes remote history';
  final git = _git(w);
  if (git == null) return null;
  final (sub, args) = git;
  final positionals = args.where((a) => !a.startsWith('-')).toList();
  return switch (sub) {
    'reset' when args.contains('--hard') || args.contains('--merge') || args.contains('--keep') =>
      'discards uncommitted changes',
    'clean' when _shortFlag(args, 'f') || args.contains('--force') => 'deletes untracked files',
    'checkout' when args.contains('--') || positionals.contains('.') || _shortFlag(args, 'f') =>
      'discards uncommitted changes',
    'restore' when !args.contains('--staged') || args.contains('--worktree') => 'discards uncommitted changes',
    'switch' when args.contains('--discard-changes') || _shortFlag(args, 'f') => 'discards uncommitted changes',
    'branch' when _shortFlag(args, 'D') || (args.contains('--delete') && args.contains('--force')) =>
      'deletes a branch that may not be merged',
    'stash' when positionals.isNotEmpty && (positionals.first == 'drop' || positionals.first == 'clear') =>
      'deletes stashed changes',
    'filter-branch' || 'filter-repo' => 'rewrites history',
    'update-ref' when _shortFlag(args, 'd') => 'deletes a ref',
    'reflog' when positionals.isNotEmpty && (positionals.first == 'expire' || positionals.first == 'delete') =>
      'deletes the reflog that undo relies on',
    'gc' when args.any((a) => a.startsWith('--prune')) => 'deletes unreachable commits',
    _ => null,
  };
}

/// Why writing [path] needs the user's eyes, or null.
String? editDangerReason(String path, {String? workingDir}) {
  final dir = workingDir;
  if (dir != null && dir.isNotEmpty && path.startsWith('/')) {
    final base = dir.endsWith('/') ? dir : '$dir/';
    if (!path.startsWith(base) && path != dir) return 'edits a file outside the project';
  }
  final rel = relativeTo(path, dir);
  final parts = rel.split('/');
  if (parts.contains('..')) return 'edits a file outside the project';
  if (parts.contains('.git')) return "edits git's internal files";
  if (rel.startsWith('.everyai/settings') || rel.contains('/.everyai/settings')) {
    return "edits the agent's own settings and permissions";
  }
  final name = parts.last;
  if (RegExp(r'^\.env(\..+)?$').hasMatch(name) && !RegExp(r'\.(example|sample|template|dist)$').hasMatch(name)) {
    return 'edits an environment file, which may hold secrets';
  }
  if (const {'id_rsa', 'id_ed25519', '.netrc', '.npmrc', '.pypirc'}.contains(name)) {
    return 'edits a file that may hold credentials';
  }
  return null;
}

// ---------------------------------------------------------------------------
// Remembered approvals.

/// Commands where any argument changes what runs, so only the exact
/// command is remembered.
const _exactOnly = {
  'python', 'python3', 'node', 'bash', 'sh', 'zsh', 'fish', 'ruby', 'perl', 'php', 'deno', 'bun', 'npx', 'pnpx', //
  'bunx', 'uvx', 'xargs', 'env', 'sudo', 'doas', 'eval', 'exec', 'timeout', 'nohup', 'ssh', 'scp', 'osascript',
  'rm', 'mv', 'cp', 'ln', 'rmdir', 'unlink', 'chmod', 'chown', 'kill', 'curl', 'wget', 'open', 'source', '.',
};

/// Programs whose first argument picks the action (`git commit`, `npm test`).
const _twoWord = {
  'git', 'npm', 'pnpm', 'yarn', 'cargo', 'go', 'dart', 'flutter', 'docker', 'kubectl', 'gh', 'uv', 'pip', 'pip3', //
  'brew', 'swift', 'zig', 'make', 'mvn', 'gradle', './gradlew', 'poetry', 'mix', 'dotnet', 'rails', 'pod',
  'xcodebuild', 'cmake', 'just', 'task', 'composer', 'bundle', 'rake', 'melos', 'nx', 'turbo',
};

/// Two-word commands whose next word picks the action (`npm run build`).
const _threeWord = {
  'npm run',
  'pnpm run',
  'yarn run',
  'docker compose',
  'dart pub',
  'flutter pub',
  'gh pr',
  'gh issue',
};

/// The rule that "allow for this session" or "always allow" would store
/// for [call], or null when it can't be remembered: compound or unparsed
/// commands, dangerous actions, edits outside the project. Commands keep
/// their program and subcommand (`npm run build` gives `npm run build *`);
/// edits keep the file (`Edit(lib/main.dart)`).
String? rememberPattern(ActionCall call, {String? workingDir}) {
  if (_command(call) case final command?) {
    if (dangerReason(command) != null) return null;
    final segments = shellSegments(command);
    if (segments == null || segments.length != 1) return null;
    final w = segments.single;
    if (w.isEmpty || RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=').hasMatch(w.first)) return null;
    // An exact rule must read back as the same words.
    bool plain(String x) => x.isNotEmpty && !x.contains('*') && !x.contains('?') && !x.contains(' ');
    String? exact() => w.every(plain) ? w.join(' ') : null;
    if (_exactOnly.contains(w.first)) return exact();
    final arity = w.length >= 2 && _threeWord.contains('${w[0]} ${w[1]}')
        ? 3
        : _twoWord.contains(w.first)
        ? 2
        : 1;
    final prefix = w.take(arity).toList();
    if (prefix.skip(1).any((x) => x.startsWith('-'))) return exact();
    if (!prefix.every(plain)) return null;
    return '${prefix.join(' ')} *';
  }
  if (_editPath(call) case final path?) {
    if (path.isEmpty || editDangerReason(path, workingDir: workingDir) != null) return null;
    final rel = relativeTo(path, workingDir);
    if (rel.startsWith('/') && workingDir != null && workingDir.isNotEmpty) return null;
    if (rel.contains('*') || rel.contains('?') || rel.contains(')')) return null;
    return 'Edit($rel)';
  }
  return null;
}

/// How long an approval lasts.
enum ApprovalScope {
  /// This action only.
  once,

  /// Until the app quits.
  session,

  /// Stored in the project's permissions.
  always,
}

// ---------------------------------------------------------------------------
// What the agent reads when an action doesn't run.

/// Why an action the agent asked for did not run.
enum DenialKind {
  /// The user said no.
  denied,

  /// Nobody answered in time.
  timedOut,

  /// The user stopped the turn while the action waited.
  cancelled,
}

const _stopClause =
    'Do not retry it, do not rephrase it, and do not reach the same outcome another way '
    '(a different command, tool or file).';

/// The tool result the agent reads for [kind]. The text is fixed so the
/// agent always gets the same unambiguous signal; the user's [reason]
/// follows word for word.
String denialMessage(DenialKind kind, {String? reason}) {
  final said = reason?.trim() ?? '';
  final head = switch (kind) {
    DenialKind.denied => '$deniedLead $_stopClause',
    DenialKind.timedOut =>
      '$timedOutLead Silence is not consent. $_stopClause Carry on with work that does not need it, or end your '
          'turn and say what is waiting on the user.',
    DenialKind.cancelled => '$cancelledLead $_stopClause',
  };
  if (said.isEmpty) {
    return kind == DenialKind.denied
        ? '$head If you cannot continue without it, end your turn and say what you needed and why.'
        : head;
  }
  return '$head\n\nThe user\'s reason, word for word (follow it if it asks for something else):\n$said';
}

const deniedLead = 'The user did NOT consent to this action, and it was not run.';
const timedOutLead = 'The approval request timed out with no answer, so this action was not run.';
const cancelledLead = 'The user cancelled this action before it ran.';
const _blockedLead = 'Blocked, not run:';

/// What the agent reads when the policy blocks [blocked] (each with its
/// decision) out of a [batch] of pending actions.
String policyDenial(List<(ActionCall, Decision)> blocked, {int batch = 1}) {
  final b = StringBuffer();
  for (final (call, d) in blocked) {
    final what = _command(call) ?? _editPath(call) ?? _readPath(call) ?? call.toolName;
    b.write('$_blockedLead `${_short(what)}` ');
    if (d.source == DecisionSource.floor) {
      b.writeln('${d.why}. This is on the safety floor and never runs, in any mode.');
    } else {
      b.writeln('the user\'s permission rule `${d.rule}` forbids it.');
    }
  }
  b.write('The user did NOT consent to this action. $_stopClause');
  if (batch > blocked.length) {
    b.write(' Nothing else in this batch ran either; re-issue the other actions on their own if you still need them.');
  }
  b.write(' If you cannot finish without it, end your turn and explain what you needed.');
  return b.toString();
}

String _short(String s) {
  final line = s.trim().replaceAll(RegExp(r'\s+'), ' ');
  return line.length <= 120 ? line : '${line.substring(0, 117)}…';
}

/// A short, user-facing version of a denial the agent was sent, for the
/// transcript ("Denied: use yarn"), or [text] itself when it isn't one.
String denialSummary(String text) {
  String withReason(String label) {
    final i = text.indexOf('word for word');
    if (i < 0) return label;
    final nl = text.indexOf('\n', i);
    return nl < 0 ? label : '$label: ${text.substring(nl + 1).trim()}';
  }

  if (text.startsWith(deniedLead)) return withReason('Denied');
  if (text.startsWith(timedOutLead)) return withReason('No answer in time');
  if (text.startsWith(cancelledLead)) return withReason('Cancelled');
  if (text.startsWith(_blockedLead)) {
    final line = text.split('\n').first.substring(_blockedLead.length).trim();
    final reason = line.contains('` ') ? line.substring(line.indexOf('` ') + 2) : line;
    return 'Blocked: ${reason.split('. This is').first.replaceAll(RegExp(r'\.$'), '')}';
  }
  return text;
}
