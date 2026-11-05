// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../environments/exec_env.dart';
import '../../harness/everyai/shell_io.dart' show ShellEnv;
import '../driver_process_io.dart' show findOnPath;
import 'desktop_apps_io.dart' show bundledHere;

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
  List<String> Function(String command)? bundled,
  Future<bool> Function(String path)? starts,
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
      // Only `<app>\bin`: an app's own folder holds its GUI exe, which is not the CLI.
      final dirs = [
        for (final child in entries(programs))
          if (isFile != null || Directory('$programs\\$child\\bin').existsSync()) '$programs\\$child\\bin',
        // Codex's installer puts its exe two levels down and adds the folder to the user PATH only (registry), which
        // a running app does not see.
        if (isFile != null || Directory('$programs\\OpenAI\\Codex\\bin').existsSync()) '$programs\\OpenAI\\Codex\\bin',
      ];
      final hit = findOnPath(command, dirs.join(';'), windows: true, isFile: isFile);
      if (hit != null) return hit;
    }
  }
  final prefix = await _npmPrefixOnce(shell, npmPrefix ?? _npmConfigPrefix);
  final inNpm = prefix == null ? null : findOnPath(command, win ? prefix : '$prefix/bin', windows: win, isFile: isFile);
  if (inNpm != null) return inNpm;
  // Last: a CLI a desktop app brought along. Only one that starts counts.
  for (final path in (bundled ?? (c) => bundledHere(c, isFile: isFile))(command)) {
    if (await (starts ?? _startsWithVersion)(path)) return path;
  }
  return null;
}

Future<bool> _startsWithVersion(String path) async {
  try {
    await _runKilling(path, ['--version'], const Duration(seconds: 4));
    return true;
  } on Object {
    return false;
  }
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
    final out = await _runKilling('npm', ['config', 'get', 'prefix'], const Duration(seconds: 4), shell);
    final line = out.split('\n').map((l) => l.trim()).firstWhere((l) => l.isNotEmpty, orElse: () => '');
    return line.isEmpty ? null : line;
  } on Object {
    return null;
  }
}

/// The usual install folders, relative to $HOME, as a shell would check them.
/// The `*` ones are globs (nvm keeps a folder per Node version).
const _homeDirs = [
  '.claude/local',
  '.local/bin',
  '.npm-global/bin',
  '.bun/bin',
  '.opencode/bin',
  '.cargo/bin',
  '.volta/bin',
  '.deno/bin',
  '.nvm/versions/node/*/bin',
];

const _marker = '__EVERYAI_CLI__';

/// The shell line [_findIn] runs: PATH first, then the folders above, then
/// npm's prefix. It prints [_marker] and the path, so a banner from
/// /etc/profile or ~/.profile is never taken for the answer. A login `sh`
/// (dash) skips ~/.bashrc, where nvm puts itself, hence the explicit folders.
String envLookupScript() {
  final dirs = ['/opt/homebrew/bin', '/usr/local/bin', for (final d in _homeDirs) '\$HOME/$d'];
  return 'found() { printf "%s\\n%s\\n" "$_marker" "\$1"; exit 0; }; '
      r'p=$(command -v "$1" 2>/dev/null); case "$p" in /*) found "$p";; esac; '
      'for d in ${dirs.map((d) => '"$d"').join(' ')}; do '
      r'[ -x "$d/$1" ] && found "$d/$1"; done; '
      r'n=$(npm config get prefix 2>/dev/null); [ -n "$n" ] && [ -x "$n/bin/$1" ] && found "$n/bin/$1"; exit 1';
}

Future<String?> _findIn(ExecEnv env, String command, Future<String> Function(String, List<String>) run) async {
  final cmd = env.wrap('sh', ['-lc', envLookupScript(), 'sh', command]);
  try {
    final lines = (await run(cmd.executable, cmd.args)).split('\n').map((l) => l.trim()).toList();
    final at = lines.indexOf(_marker);
    if (at < 0 || at + 1 >= lines.length) return null;
    final path = lines[at + 1];
    return path.startsWith('/') ? path : null;
  } on Object {
    return null;
  }
}

/// Runs [executable] and returns its stdout, killing it when [limit] passes
/// (`Process.run(...).timeout` would leave it running). Throws on a failure.
Future<String> _runKilling(String executable, List<String> args, Duration limit, [Map<String, String>? env]) async {
  final proc = await Process.start(executable, args, environment: env, runInShell: Platform.isWindows);
  final out = proc.stdout.transform(utf8.decoder).join();
  unawaited(proc.stderr.drain<void>());
  final code = await proc.exitCode.timeout(
    limit,
    onTimeout: () {
      proc.kill();
      throw TimeoutException('$executable did not answer', limit);
    },
  );
  if (code != 0) throw ProcessException(executable, args, 'exit $code', code);
  return out;
}

/// A cold WSL distro can take a while to start.
Future<String> _runOnHost(String executable, List<String> args) =>
    _runKilling(executable, args, const Duration(seconds: 25));
