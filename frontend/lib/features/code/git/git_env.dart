// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../environments/exec_env.dart';

/// A folder whose git runs inside an environment, and the host path of the
/// folder EveryAI keeps that repository's worktrees and hooks in there
/// (`$HOME/.local/share/everyai` inside).
typedef GitInside = ({ExecEnv env, String dataDir});

/// Where git runs for a folder: inside an environment, or (null) on this
/// computer. Set by Code's controller from the environments it found;
/// tests set their own. Unset, every folder uses this computer's git.
Future<GitInside?> Function(String dir)? gitInsideOf;

final _wslNative = RegExp(r'^[\\/]{2}(?:wsl\$|wsl\.localhost)[\\/]([^\\/]+)', caseSensitive: false);

/// The distro whose own files [hostPath] is in (`\\wsl.localhost\<distro>\…`,
/// `\\wsl$\<distro>\…`), or null.
String? wslDistroOf(String hostPath) => _wslNative.firstMatch(hostPath)?.group(1);

/// The `\\wsl.localhost\<distro>` or `\\wsl$\<distro>` part of [hostPath], as written, or null.
String? wslPrefixOf(String hostPath) => _wslNative.firstMatch(hostPath)?.group(0);

/// [hostPath] (a distro path as this computer sees it, `\\wsl.localhost\<distro>\…`) with the distro prefix
/// [dir] was given in (`\\wsl$\Ubuntu`, another case), so it still matches the project's own path.
String hostLike(String hostPath, String dir) {
  final from = wslPrefixOf(hostPath), to = wslPrefixOf(dir);
  if (from == null || to == null || from == to) return hostPath;
  if (wslDistroOf(from)!.toLowerCase() != wslDistroOf(to)!.toLowerCase()) return hostPath;
  return '$to${hostPath.substring(from.length)}';
}

/// Whether git for [hostPath] runs inside [env]: only a WSL distro's own
/// files, where Windows git over the network share is slow and gets file
/// modes and line endings wrong. `/mnt/c` projects, bind mounts, shared
/// folders and sshfs mounts are this computer's files and use its git.
bool gitRunsInside(ExecEnv env, String hostPath) => env.kind == EnvKind.wsl && wslDistroOf(hostPath) != null;

/// An argument that is a host path the environment can see: a drive path
/// (`C:\…`) or a network path (`\\…`). Other arguments (refs, options,
/// relative paths, messages) never change.
final _hostPathArg = RegExp(r'^(?:[A-Za-z]:[\\/]|[\\/]{2})');

/// [arg] as [env] sees it, when it's a host path it can see.
String envArg(ExecEnv env, String arg) => _hostPathArg.hasMatch(arg) ? env.toEnvPath(arg) ?? arg : arg;

/// Where EveryAI keeps [repo]'s worktrees and hooks when its git runs inside
/// an environment (its `$HOME/.local/share/everyai`, so they are that
/// distro's own files too); null for this computer's app data.
Future<String?> gitDataDirInside(String repo) async {
  final inside = await gitInsideOf?.call(repo);
  return inside != null && gitRunsInside(inside.env, repo) ? inside.dataDir : null;
}
