// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../environments/exec_env.dart';
import '../../harness/everyai/shell_io.dart' show ShellEnv;
import '../driver_process_io.dart' show findOnPath;

/// Where [findCli] looks for [command]: the login shell's PATH (which already
/// holds the usual install folders), then the folders a vendor's installer
/// uses that are not on PATH, then npm's real global prefix. Returns the path,
/// or null. In another environment ([env], a WSL distro and so on) one
/// shell line there does the same, so the answer is a path inside it.
///
/// [loadEnv], [isFile], [list] and [npmPrefix] are for tests.
Future<String?> findCli(
  String command, {
  ExecEnv env = HostEnv.instance,
  Future<Map<String, String>> Function()? loadEnv,
  bool? windows,
  bool Function(String path)? isFile,
  List<String> Function(String dir)? list,
  Future<String?> Function(Map<String, String> env)? npmPrefix,
  Future<String> Function(String executable, List<String> args)? run,
}) async {
  if (!env.isHost) return _findIn(env, command, run ?? _runOnHost);
  final shell = await (loadEnv ?? () async => (await ShellEnv.load()).env)();
  final win = windows ?? Platform.isWindows;
  final path = shell[win ? shell.keys.firstWhere((k) => k.toUpperCase() == 'PATH', orElse: () => 'Path') : 'PATH'];
  final onPath = findOnPath(command, path ?? '', windows: win, isFile: isFile);
  if (onPath != null) return onPath;
  if (win) {
    final local = shell['LOCALAPPDATA'];
    if (local != null && local.isNotEmpty) {
      final programs = '$local\\Programs';
      final entries = list ?? _entries;
      final dirs = [
        for (final child in entries(programs)) ...['$programs\\$child\\bin', '$programs\\$child'],
      ];
      final hit = findOnPath(command, dirs.join(';'), windows: true, isFile: isFile);
      if (hit != null) return hit;
    }
  }
  final prefix = await _npmPrefixOnce(shell, npmPrefix ?? _npmConfigPrefix);
  if (prefix == null) return null;
  return findOnPath(command, win ? prefix : '$prefix/bin', windows: win, isFile: isFile);
}

List<String> _entries(String dir) {
  try {
    return [for (final e in Directory(dir).listSync()) e.path.split(Platform.pathSeparator).last];
  } on Object {
    return const [];
  }
}

/// `npm config get prefix` answered once per captured environment: a
/// reloaded login shell is a new map, so the next miss asks again.
final _prefixes = Expando<Future<String?>>('npm prefix');

Future<String?> _npmPrefixOnce(Map<String, String> shell, Future<String?> Function(Map<String, String>) probe) =>
    _prefixes[shell] ??= probe(shell);

Future<String?> _npmConfigPrefix(Map<String, String> shell) async {
  try {
    final res = await Process.run(
      'npm',
      ['config', 'get', 'prefix'],
      environment: shell,
      runInShell: Platform.isWindows,
      stdoutEncoding: utf8,
    ).timeout(const Duration(seconds: 4));
    if (res.exitCode != 0) return null;
    final line = '${res.stdout}'.split('\n').map((l) => l.trim()).firstWhere((l) => l.isNotEmpty, orElse: () => '');
    return line.isEmpty ? null : line;
  } on Object {
    return null;
  }
}

/// The usual install folders, relative to $HOME, as a shell would check them.
const _homeDirs = ['.claude/local', '.local/bin', '.npm-global/bin', '.bun/bin', '.opencode/bin', '.cargo/bin'];

Future<String?> _findIn(ExecEnv env, String command, Future<String> Function(String, List<String>) run) async {
  const name = r'"$1"';
  final dirs = ['/opt/homebrew/bin', '/usr/local/bin', for (final d in _homeDirs) '\$HOME/$d'];
  final script =
      'command -v $name 2>/dev/null && exit 0; '
      'for d in ${dirs.map((d) => '"$d"').join(' ')}; do '
      '[ -x "\$d/$name" ] && { echo "\$d/$name"; exit 0; }; done; exit 1';
  final cmd = env.wrap('sh', ['-lc', script, 'sh', command]);
  try {
    final out = await run(cmd.executable, cmd.args);
    final first = out.split('\n').map((l) => l.trim()).firstWhere((l) => l.isNotEmpty, orElse: () => '');
    return first.isEmpty ? null : first;
  } on Object {
    return null;
  }
}

Future<String> _runOnHost(String executable, List<String> args) async {
  final res = await Process.run(executable, args, stdoutEncoding: utf8).timeout(const Duration(seconds: 8));
  if (res.exitCode != 0) throw ProcessException(executable, args, 'not found', res.exitCode);
  return '${res.stdout}';
}
