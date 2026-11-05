// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'everyai.dart' show gitBashMissing;

/// What the EveryAI harness's shell tool says on Windows without Git Bash.
const gitBashMissingMessage =
    'Commands need Git for Windows (Git Bash). Install it from https://git-scm.com/download/win or with '
    '`winget install --id Git.Git -e`, then restart.';

/// True on Windows when Git Bash isn't installed (the EveryAI harness can't
/// run commands then); false everywhere else.
final gitBashMissingProvider = Provider<bool>((ref) => gitBashMissing());

/// Git for Windows' `bin\bash.exe`, or null. That one is a launcher that
/// puts Git's coreutils on PATH; `usr\bin\bash.exe` alone doesn't. First the
/// Git on PATH (`Git\cmd`, `Git\bin` or `Git\mingw64\bin` holds git.exe;
/// not Cygwin's, whose `pwd` has no `-W`),
/// then the usual install folders (all users, per user, Scoop). Never the
/// WSL launchers in System32 or WindowsApps. [env] keys match in any case.
String? findGitBash(Map<String, String> env, bool Function(String file) exists) {
  String? get(String name) {
    for (final e in env.entries) {
      if (e.key.toUpperCase() == name.toUpperCase() && e.value.trim().isNotEmpty) return e.value.trim();
    }
    return null;
  }

  String strip(String dir) => dir.endsWith('\\') || dir.endsWith('/') ? dir.substring(0, dir.length - 1) : dir;
  String parent(String dir) {
    final at = strip(dir).lastIndexOf(RegExp(r'[\\/]'));
    return at <= 0 ? dir : dir.substring(0, at);
  }

  final systemRoot = (get('SystemRoot') ?? r'C:\Windows').toLowerCase();
  bool wsl(String file) {
    final f = file.toLowerCase().replaceAll('/', '\\');
    return f.startsWith('${strip(systemRoot)}\\') || f.contains('\\windowsapps\\');
  }

  // A Git for Windows top folder has git-bash.exe (full and portable) or
  // mingw64\bin\git.exe; Cygwin's bin (git.exe next to bash.exe) has neither.
  bool gitForWindows(String top) => exists('$top\\git-bash.exe') || exists('$top\\mingw64\\bin\\git.exe');
  final candidates = [
    for (final raw in (get('PATH') ?? '').split(';'))
      if (raw.trim().replaceAll('"', '') case final dir when dir.isNotEmpty && exists('${strip(dir)}\\git.exe'))
        for (final top in [parent(dir), parent(parent(dir))])
          if (gitForWindows(top)) '$top\\bin\\bash.exe',
    for (final root in ['ProgramW6432', 'ProgramFiles', 'ProgramFiles(x86)'])
      if (get(root) case final r?) '${strip(r)}\\Git\\bin\\bash.exe',
    if (get('LOCALAPPDATA') case final l?) '${strip(l)}\\Programs\\Git\\bin\\bash.exe',
    if (get('USERPROFILE') case final u?) '${strip(u)}\\scoop\\apps\\git\\current\\bin\\bash.exe',
  ];
  for (final c in candidates) {
    if (!wsl(c) && exists(c)) return c;
  }
  return null;
}
